//! 压缩包：按 URL 后缀判类型，用系统 `tar` 解压（不引 zip / tar / flate2 —— CLAUDE.md 规则 1 清单之外；
//! Windows 10 1803+ 自带 `C:\Windows\System32\tar.exe`（bsdtar，zip / tar.gz / tar.bz2 都认），macOS 的 tar 也是 bsdtar，
//! Linux 的 GNU tar 不认 zip 时回落 `unzip`）。
//! Derived from zed-industries/zed crates/project/src/agent_server_store.rs @ d9e1c024f393832765a03f4de204d6c8cd9abcb2 (GPL-3.0-or-later)
//! （`registry_archive_kind_for_url` / `raw_binary_file_name` 的分类规则；解压本身不复用 Zed 的 async_zip / async-tar。）

use std::path::{Path, PathBuf};

use crate::{RegistryError, Result, command, resolve_program};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ArchiveKind {
    Zip,
    TarGz,
    TarBz2,
    /// URL 直接指向可执行文件（registry schema 允许「raw binary」）。
    RawBinary { file_name: String },
}

impl ArchiveKind {
    /// 落盘用的文件名（压缩包按后缀取；raw 用 URL 里的文件名）。
    pub fn file_name(&self, fallback: &str) -> String {
        match self {
            ArchiveKind::Zip => format!("{fallback}.zip"),
            ArchiveKind::TarGz => format!("{fallback}.tar.gz"),
            ArchiveKind::TarBz2 => format!("{fallback}.tar.bz2"),
            ArchiveKind::RawBinary { file_name } => file_name.clone(),
        }
    }
}

/// 明确不支持的后缀（安装器格式与我们解不开的格式），与 Zed 一致。
const UNSUPPORTED_SUFFIXES: &[&str] = &[
    ".dmg", ".pkg", ".deb", ".rpm", ".msi", ".appimage", ".tar.xz", ".txz", ".tar", ".gz", ".bz2", ".xz", ".7z",
];

/// 只看 URL 的路径部分（去掉 query / fragment）。
fn url_path(url: &str) -> &str {
    let without_fragment = url.split('#').next().unwrap_or(url);
    let without_query = without_fragment.split('?').next().unwrap_or(without_fragment);
    // 跳过 scheme://host
    match without_query.find("://") {
        Some(i) => match without_query[i + 3..].find('/') {
            Some(j) => &without_query[i + 3 + j..],
            None => "",
        },
        None => without_query,
    }
}

pub fn kind_for_url(url: &str) -> Result<ArchiveKind> {
    let path = url_path(url);
    let lower = path.to_ascii_lowercase();
    if lower.ends_with(".zip") {
        return Ok(ArchiveKind::Zip);
    }
    if lower.ends_with(".tar.gz") || lower.ends_with(".tgz") {
        return Ok(ArchiveKind::TarGz);
    }
    if lower.ends_with(".tar.bz2") || lower.ends_with(".tbz2") {
        return Ok(ArchiveKind::TarBz2);
    }
    if let Some(suffix) = UNSUPPORTED_SUFFIXES.iter().find(|s| lower.ends_with(*s)) {
        return Err(RegistryError::Unsupported(format!("不支持的压缩包类型 {suffix}：{url}")));
    }
    let file_name = raw_binary_file_name(path).ok_or_else(|| RegistryError::Unsupported(format!("URL 里没有文件名：{url}")))?;
    Ok(ArchiveKind::RawBinary { file_name })
}

fn raw_binary_file_name(path: &str) -> Option<String> {
    let last = path.rsplit('/').next().filter(|s| !s.is_empty())?;
    let decoded = percent_decode(last);
    if decoded.is_empty() || decoded == "." || decoded == ".." || decoded.contains(['/', '\\', '\0']) {
        return None;
    }
    Some(decoded)
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && i + 2 < bytes.len()
            && let (Some(h), Some(l)) = (hex(bytes.get(i + 1).copied()), hex(bytes.get(i + 2).copied()))
        {
            out.push(h * 16 + l);
            i += 3;
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn hex(b: Option<u8>) -> Option<u8> {
    match b? {
        c @ b'0'..=b'9' => Some(c - b'0'),
        c @ b'a'..=b'f' => Some(c - b'a' + 10),
        c @ b'A'..=b'F' => Some(c - b'A' + 10),
        _ => None,
    }
}

/// 系统 `tar`：Windows 先取 `%SystemRoot%\System32\tar.exe`（bsdtar）——PATH 上可能排在前面的是 Git for Windows 的
/// GNU tar，它把 `C:\…` 当成远程主机（`Cannot connect to C: resolve failed`，R5 实测）；其他平台取 PATH 上的。
pub fn tar_program() -> PathBuf {
    if cfg!(windows)
        && let Some(root) = std::env::var_os("SystemRoot")
    {
        let system = PathBuf::from(root).join("System32").join("tar.exe");
        if system.is_file() {
            return system;
        }
    }
    resolve_program("tar")
}

/// 把 `archive` 解到 `dest`（须已存在且为空目录）。raw binary 只是移动进去（unix 上加可执行位）。
pub async fn extract(kind: &ArchiveKind, archive: &Path, dest: &Path) -> Result<()> {
    match kind {
        ArchiveKind::RawBinary { file_name } => {
            let target = dest.join(file_name);
            tokio::fs::rename(archive, &target).await?;
            make_executable(&target)?;
            Ok(())
        }
        ArchiveKind::Zip | ArchiveKind::TarGz | ArchiveKind::TarBz2 => {
            let tar = tar_program();
            let output = command(&tar).arg("-xf").arg(archive).arg("-C").arg(dest).output().await.map_err(|e| {
                RegistryError::Archive(format!("拉不起 {}：{e}（Windows 10 1803+ 自带 tar.exe；其他平台请装 tar）", tar.display()))
            })?;
            if output.status.success() {
                return Ok(());
            }
            let stderr = String::from_utf8_lossy(&output.stderr);
            // GNU tar 不认 zip：回落 unzip。
            if *kind == ArchiveKind::Zip && !cfg!(windows) {
                let unzip = resolve_program("unzip");
                if unzip.is_file() {
                    let out = command(&unzip).arg("-q").arg("-o").arg(archive).arg("-d").arg(dest).output().await?;
                    if out.status.success() {
                        return Ok(());
                    }
                    return Err(RegistryError::Archive(crate::tail(&String::from_utf8_lossy(&out.stderr), 2048)));
                }
            }
            Err(RegistryError::Archive(crate::tail(&stderr, 2048)))
        }
    }
}

#[cfg(unix)]
pub fn make_executable(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let mut perms = std::fs::metadata(path)?.permissions();
    perms.set_mode(perms.mode() | 0o755);
    std::fs::set_permissions(path, perms)?;
    Ok(())
}

#[cfg(not(unix))]
pub fn make_executable(_path: &Path) -> Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_supported_suffixes_and_raw_binaries() {
        assert_eq!(kind_for_url("https://downloads.cursor.com/x/y/agent-cli-package.zip").expect("zip"), ArchiveKind::Zip);
        assert_eq!(kind_for_url("https://example.test/a.tar.gz?token=1").expect("tgz"), ArchiveKind::TarGz);
        assert_eq!(kind_for_url("https://example.test/a.TGZ").expect("tgz"), ArchiveKind::TarGz);
        assert_eq!(kind_for_url("https://example.test/a.tbz2").expect("tbz2"), ArchiveKind::TarBz2);
        assert_eq!(
            kind_for_url("https://github.com/o/r/releases/download/v1/agent%20cli").expect("raw"),
            ArchiveKind::RawBinary { file_name: "agent cli".into() }
        );
        assert!(matches!(kind_for_url("https://example.test/a.dmg"), Err(RegistryError::Unsupported(_))));
        assert!(matches!(kind_for_url("https://example.test/a.tar.xz"), Err(RegistryError::Unsupported(_))));
        assert!(matches!(kind_for_url("https://example.test/"), Err(RegistryError::Unsupported(_))));
    }

    /// Windows 实测项（规则 9）：系统 tar 解一个 zip，路径含空格与中文。
    #[tokio::test]
    async fn system_tar_extracts_a_zip_into_a_non_ascii_dir() {
        let base = std::env::temp_dir().join(format!("acp-registry-tar 测试-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let src = base.join("src");
        std::fs::create_dir_all(src.join("dist-package")).expect("mkdir");
        std::fs::write(src.join("dist-package").join("agent.cmd"), b"@echo off\r\necho hi\r\n").expect("write");
        let zip = base.join("包 archive.zip");
        // 用同一个 tar 打包（-a 按后缀选格式）。
        let status = command(tar_program()).arg("-a").arg("-cf").arg(&zip).arg("-C").arg(&src).arg("dist-package").output().await.expect("tar -c");
        assert!(status.status.success(), "{}", String::from_utf8_lossy(&status.stderr));
        let dest = base.join("目标 dir");
        std::fs::create_dir_all(&dest).expect("mkdir");
        extract(&ArchiveKind::Zip, &zip, &dest).await.expect("extract");
        assert!(dest.join("dist-package").join("agent.cmd").is_file());
        let _ = std::fs::remove_dir_all(&base);
    }
}
