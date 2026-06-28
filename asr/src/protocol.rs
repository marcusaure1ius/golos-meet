use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Движок распознавания речи.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum ModelKind {
    /// GigaAM-v3 ONNX CTC (по умолчанию, быстро).
    #[default]
    Gigaam,
    /// Whisper large-v3 через whisper.cpp / GGML (качество).
    Whisper,
}

/// Сообщения от Swift app в sidecar (по stdin, JSON-lines).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Request {
    /// Загрузить модель. kind определяет движок (по умолчанию gigaam). Должно прийти один раз перед begin_session.
    Load { id: u64, model_path: PathBuf, #[serde(default)] kind: ModelKind },
    /// Начать новую сессию записи. Аудио идёт по audio-fd.
    BeginSession { id: u64 },
    /// Закончить сессию. Sidecar финализирует и шлёт Response::Final.
    EndSession { id: u64, samples_total: u64 },
    /// Прервать текущую сессию без транскрипции.
    Cancel { id: u64 },
    /// Запросить graceful shutdown.
    Shutdown { id: u64 },
    /// Транскрибировать готовый WAV-файл целиком (VAD-сегментация внутри).
    TranscribeFile { id: u64, path: PathBuf },
}

impl Request {
    pub fn id(&self) -> u64 {
        match self {
            Request::Load { id, .. } => *id,
            Request::BeginSession { id } => *id,
            Request::EndSession { id, .. } => *id,
            Request::Cancel { id } => *id,
            Request::Shutdown { id } => *id,
            Request::TranscribeFile { id, .. } => *id,
        }
    }
}

/// Один речевой сегмент с таймкодами в секундах от начала файла.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TimedSegment {
    pub start: f32,
    pub end: f32,
    pub text: String,
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
    /// Результат transcribe_file: список сегментов с таймкодами.
    Segments { id: u64, segments: Vec<TimedSegment>, duration_ms: u64 },
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn load_kind_defaults_to_gigaam() {
        // load без поля kind → ModelKind::Gigaam
        let json = r#"{"type":"load","id":1,"model_path":"/models/gigaam"}"#;
        let req: Request = serde_json::from_str(json).unwrap();
        assert_eq!(req, Request::Load { id: 1, model_path: "/models/gigaam".into(), kind: ModelKind::Gigaam });
        // load с kind:"whisper" → ModelKind::Whisper
        let json2 = r#"{"type":"load","id":2,"model_path":"/models/ggml.bin","kind":"whisper"}"#;
        let req2: Request = serde_json::from_str(json2).unwrap();
        assert_eq!(req2, Request::Load { id: 2, model_path: "/models/ggml.bin".into(), kind: ModelKind::Whisper });
    }

    #[test]
    fn transcribe_file_request_roundtrips() {
        let json = r#"{"type":"transcribe_file","id":7,"path":"/tmp/mic.wav"}"#;
        let req: Request = serde_json::from_str(json).unwrap();
        assert_eq!(req, Request::TranscribeFile { id: 7, path: "/tmp/mic.wav".into() });
        assert_eq!(req.id(), 7);
        // serialize back and confirm the snake_case tag round-trips
        let out = serde_json::to_string(&req).unwrap();
        assert!(out.contains(r#""type":"transcribe_file""#));
        let back: Request = serde_json::from_str(&out).unwrap();
        assert_eq!(back, req);
    }

    #[test]
    fn segments_response_serializes_snake_case() {
        let resp = Response::Segments {
            id: 7,
            segments: vec![TimedSegment { start: 0.0, end: 1.5, text: "привет".into() }],
            duration_ms: 1500,
        };
        let line = resp.to_line();
        assert!(line.contains(r#""type":"segments""#));
        assert!(line.contains(r#""duration_ms":1500"#));
        assert!(line.contains(r#""start":0.0"#));
    }
}
