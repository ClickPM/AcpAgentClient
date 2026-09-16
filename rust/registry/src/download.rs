//! 带进度与 sha256 的流式下载（binary 型压缩包与受管 Node 共用）。
//! Derived from zed-industries/zed crates/http_client/src/github_download.rs @ d9e1c024f393832765a03f4de204d6c8cd9abcb2 (GPL-3.0-or-later)
//! （转写 `download_server_raw_binary` 的「边写边算 sha256、先落临时文件」；块与块之间检查取消。）

use std::path::Path;
use std::time::Duration;

use sha2::{Digest, Sha256};
use tokio::io::AsyncWriteExt;

use crate::{CancelToken, RegistryError, Result};

/// 建立连接的超时；整体没有超时（大包看进度，取消靠 [`CancelToken`]）。
const CONNECT_TIMEOUT: Duration = Duration::from_secs(30);

pub fn client() -> reqwest::Client {
    reqwest::Client::builder()
        .connect_timeout(CONNECT_TIMEOUT)
        .user_agent(concat!("AcpAgentClient/", env!("CARGO_PKG_VERSION")))
        .build()
        .unwrap_or_else(|_| reqwest::Client::new())
}

/// 下载到 `dest`（父目录须已存在），逐块回调 `(done, total)`，返回小写十六进制 sha256。
/// 非 2xx 报 `Http`；取消时删掉半截文件并报 `Cancelled`。
pub async fn download_to_file(
    http: &reqwest::Client,
    url: &str,
    dest: &Path,
    cancel: &CancelToken,
    mut on_progress: impl FnMut(u64, Option<u64>),
) -> Result<String> {
    cancel.check()?;
    let response = http.get(url).send().await.map_err(|e| RegistryError::Http(format!("{url}：{e}")))?;
    let status = response.status();
    if !status.is_success() {
        return Err(RegistryError::Http(format!("{url} 返回 {}", status.as_u16())));
    }
    let total = response.content_length();
    let mut response = response;
    let mut file = tokio::fs::File::create(dest).await?;
    let mut hasher = Sha256::new();
    let mut done: u64 = 0;
    on_progress(0, total);
    let result: Result<()> = async {
        loop {
            let chunk = tokio::select! {
                chunk = response.chunk() => chunk.map_err(|e| RegistryError::Http(format!("{url}：{e}")))?,
                _ = cancel.cancelled() => return Err(RegistryError::Cancelled),
            };
            let Some(bytes) = chunk else { break };
            hasher.update(&bytes);
            file.write_all(&bytes).await?;
            done += bytes.len() as u64;
            on_progress(done, total);
        }
        file.flush().await?;
        Ok(())
    }
    .await;
    drop(file);
    if let Err(e) = result {
        let _ = tokio::fs::remove_file(dest).await;
        return Err(e);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

/// 一个文件的 sha256（安装后自检 / 测试用）。
pub fn sha256_file(path: &Path) -> Result<String> {
    let bytes = std::fs::read(path)?;
    let mut hasher = Sha256::new();
    hasher.update(&bytes);
    Ok(format!("{:x}", hasher.finalize()))
}

/// 大小写不敏感地比较两个十六进制 sha256。
pub fn sha256_matches(actual: &str, expected: &str) -> bool {
    actual.trim().eq_ignore_ascii_case(expected.trim())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha256_of_known_bytes() {
        let dir = std::env::temp_dir().join(format!("acp-registry-sha-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("mkdir");
        let f = dir.join("abc.txt");
        std::fs::write(&f, b"abc").expect("write");
        assert_eq!(sha256_file(&f).expect("sha"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        assert!(sha256_matches("BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD", &sha256_file(&f).expect("sha")));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
