//! Движок-агностичная обёртка вокруг `transcribe-rs`.
//! Поддерживает GigaAM-v3 ONNX (kind = gigaam) и Whisper GGML (kind = whisper).

use anyhow::{Context, Result};
use std::path::{Path, PathBuf};
use std::time::Instant;
use transcribe_rs::SpeechModel;
use transcribe_rs::onnx::Quantization;
use transcribe_rs::onnx::gigaam::GigaAMModel;
use transcribe_rs::whisper_cpp::WhisperEngine;

use crate::protocol::ModelKind;

pub struct Transcriber {
    model: Box<dyn SpeechModel + Send>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct TranscribeResult {
    pub text: String,
    pub duration_ms: u64,
}

impl Transcriber {
    /// Загрузить модель указанного движка.
    /// - `ModelKind::Gigaam` — model_path это директория с ONNX-бандлом.
    /// - `ModelKind::Whisper` — model_path это `.bin` GGML-файл.
    pub fn load(model_path: &Path, kind: ModelKind) -> Result<Self> {
        let model: Box<dyn SpeechModel + Send> = match kind {
            ModelKind::Gigaam => {
                let m = GigaAMModel::load(&PathBuf::from(model_path), &Quantization::default())
                    .with_context(|| format!("load GigaAM model from {:?}", model_path))?;
                Box::new(m)
            }
            ModelKind::Whisper => {
                let m = WhisperEngine::load(model_path)
                    .map_err(|e| anyhow::anyhow!("load Whisper model from {:?}: {}", model_path, e))?;
                Box::new(m)
            }
        };
        Ok(Self { model })
    }

    /// Транскрибировать WAV-файл (16kHz mono Int16). Блокирующий вызов.
    pub fn transcribe_wav(&mut self, wav_path: &Path) -> Result<TranscribeResult> {
        let started = Instant::now();
        let result = self.model
            .transcribe_file(
                &PathBuf::from(wav_path),
                &transcribe_rs::TranscribeOptions::default(),
            )
            .context("transcribe_file")?;
        Ok(TranscribeResult {
            text: result.text,
            duration_ms: started.elapsed().as_millis() as u64,
        })
    }

    /// Транскрибировать срез сэмплов (16kHz mono f32). Используется для
    /// поштучной транскрибации речевых регионов из VAD-сегментации.
    /// Возвращает только текст; таймкоды добавляет вызывающий по позиции куска.
    pub fn transcribe_samples(&mut self, samples: &[f32]) -> Result<String> {
        let opts = transcribe_rs::TranscribeOptions::default();
        let result = self.model.transcribe(samples, &opts)
            .context("transcribe_samples")?;
        Ok(result.text)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Этот тест требует реальной модели GigaAM на диске. Включается переменной окружения
    /// `GOLOS_ASR_MODEL_DIR` указывающей на распакованный ONNX-bundle. Если переменная
    /// не задана — тест пропускается (вместо false negative в CI без модели).
    #[test]
    fn transcribes_sample_with_loaded_model() {
        let model_dir = match std::env::var("GOLOS_ASR_MODEL_DIR") {
            Ok(s) => s,
            Err(_) => {
                eprintln!("skipping: GOLOS_ASR_MODEL_DIR not set");
                return;
            }
        };
        let mut t = Transcriber::load(Path::new(&model_dir), ModelKind::Gigaam)
            .expect("model should load");
        let wav = Path::new("tests/fixtures/sample_ru_short.wav");
        if !wav.exists() {
            eprintln!("skipping: fixture {:?} missing", wav);
            return;
        }
        let r = t.transcribe_wav(wav).expect("transcribe should succeed");
        assert!(!r.text.is_empty(), "non-empty text expected");
        let lower = r.text.to_lowercase();
        assert!(
            lower.contains("привет") || lower.contains("тестов") || lower.contains("запис"),
            "expected one of [привет, тестов, запис] tokens in: {:?}",
            r.text
        );
        assert!(r.duration_ms > 0);
    }

    #[test]
    fn load_returns_err_for_missing_model_dir() {
        let r = Transcriber::load(Path::new("/nonexistent/path"), ModelKind::Gigaam);
        assert!(r.is_err());
    }
}
