//! 核心的错误边界：所有对外函数返回 [`Result`]，桥层把 [`CoreError`] 翻成 Dart 异常。

use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum CoreError {
    /// 传入的数据目录不可用（非绝对路径、建不出来）。
    InvalidDataDir(String),
    /// 文件系统错误。
    Io(String),
    /// JSON 编解码错误。
    Json(String),
    /// 该功能在后续轮次实现（值是轮次号，例如 "R1"）。
    NotImplemented(&'static str),
}

impl CoreError {
    /// 稳定的短码，桥层原样带给 Dart（`BridgeError.code`）。
    pub fn code(&self) -> &'static str {
        match self {
            CoreError::InvalidDataDir(_) => "invalid_data_dir",
            CoreError::Io(_) => "io",
            CoreError::Json(_) => "json",
            CoreError::NotImplemented(_) => "not_implemented",
        }
    }
}

impl fmt::Display for CoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CoreError::InvalidDataDir(p) => write!(f, "invalid data dir: {p}"),
            CoreError::Io(e) => write!(f, "io error: {e}"),
            CoreError::Json(e) => write!(f, "json error: {e}"),
            CoreError::NotImplemented(round) => write!(f, "not implemented until {round}"),
        }
    }
}

impl std::error::Error for CoreError {}

impl From<std::io::Error> for CoreError {
    fn from(e: std::io::Error) -> Self {
        CoreError::Io(e.to_string())
    }
}

impl From<serde_json::Error> for CoreError {
    fn from(e: serde_json::Error) -> Self {
        CoreError::Json(e.to_string())
    }
}

pub type Result<T> = std::result::Result<T, CoreError>;
