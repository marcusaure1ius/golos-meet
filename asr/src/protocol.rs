use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Сообщения от Swift app в sidecar (по stdin, JSON-lines).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Request {
    /// Загрузить модель из директории. Должно прийти один раз перед begin_session.
    Load { id: u64, model_path: PathBuf },
    /// Начать новую сессию записи. Аудио идёт по audio-fd.
    BeginSession { id: u64 },
    /// Закончить сессию. Sidecar финализирует и шлёт Response::Final.
    EndSession { id: u64, samples_total: u64 },
    /// Прервать текущую сессию без транскрипции.
    Cancel { id: u64 },
    /// Запросить graceful shutdown.
    Shutdown { id: u64 },
}

impl Request {
    pub fn id(&self) -> u64 {
        match self {
            Request::Load { id, .. } => *id,
            Request::BeginSession { id } => *id,
            Request::EndSession { id, .. } => *id,
            Request::Cancel { id } => *id,
            Request::Shutdown { id } => *id,
        }
    }
}

/// Сообщения от sidecar в Swift app (по stdout, JSON-lines).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Response {
    /// Sidecar поднялся и готов к Load. (Unsolicited — без id.)
    Hello { version: String },
    /// Модель загружена, можно начинать сессии.
    Ready { id: u64 },
    /// Сессия начата, sidecar читает audio-fd.
    SessionStarted { id: u64 },
    /// Партиал-транскрипт. В MVP не отправляется — зарезервировано на будущее.
    #[allow(dead_code)]
    Partial { text: String },
    /// Финальный transcript после end_session.
    Final { id: u64, text: String, duration_ms: u64 },
    /// Сессия отменена (после Cancel).
    Cancelled { id: u64 },
    /// Любая ошибка. id=None если ошибка при парсинге JSON.
    Error { id: Option<u64>, kind: String, message: String },
}

impl Response {
    /// Сериализует и добавляет '\n' (JSON-lines convention).
    pub fn to_line(&self) -> String {
        let mut s = serde_json::to_string(self).expect("Response must serialize");
        s.push('\n');
        s
    }
}
