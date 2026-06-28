//! Тонкая обёртка вокруг `transcribe-rs` для GigaAM-v3 ONNX.

use anyhow::{Context, Result};
use std::path::{Path, PathBuf};
use std::time::Instant;
use transcribe_rs::SpeechModel;
use transcribe_rs::onnx::Quantization;
use transcribe_rs::onnx::gigaam::GigaAMModel;

pub struct Transcriber {
    model: GigaAMModel,
}

#[derive(Debug, Clone, PartialEq)]
pub struct TranscribeResult {
    pub text: String,
    pub duration_ms: u64,
}

impl Transcriber {
    /// Загрузить ONNX-модель GigaAM-v3 из директории.
    pub fn load(model_dir: &Path) -> Result<Self> {
        let model = GigaAMModel::load(&PathBuf::from(model_dir), &Quantization::default())
            .with_context(|| format!("load GigaAM model from {:?}", model_dir))?;
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
        let mut t = Transcriber::load(Path::new(&model_dir))
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
        let r = Transcriber::load(Path::new("/nonexistent/path"));
        assert!(r.is_err());
    }
}
