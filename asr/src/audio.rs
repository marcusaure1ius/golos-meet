//! Буфер аудио-сэмплов (16kHz mono Int16 PCM) и запись в WAV.

use anyhow::{Context, Result};
use std::io::Read;
use std::path::Path;

/// Аккумулятор PCM сэмплов одной сессии.
#[derive(Debug, Default)]
pub struct AudioBuffer {
    samples: Vec<i16>,
}

impl AudioBuffer {
    pub fn new() -> Self { Self::default() }

    /// Добавить сэмплы (например, после чтения из pipe).
    pub fn extend(&mut self, more: &[i16]) {
        self.samples.extend_from_slice(more);
    }

    /// Сколько сэмплов накоплено.
    pub fn len(&self) -> usize { self.samples.len() }
    pub fn is_empty(&self) -> bool { self.samples.is_empty() }

    /// Длительность накопленного аудио в миллисекундах при заданной частоте.
    pub fn duration_ms(&self, sample_rate_hz: u32) -> u64 {
        ((self.samples.len() as u64) * 1000) / (sample_rate_hz as u64).max(1)
    }

    /// Очистить буфер для следующей сессии.
    pub fn clear(&mut self) { self.samples.clear(); }

    /// Записать накопленные сэмплы в WAV-файл (16kHz mono Int16).
    pub fn write_wav(&self, path: &Path, sample_rate_hz: u32) -> Result<()> {
        let spec = hound::WavSpec {
            channels: 1,
            sample_rate: sample_rate_hz,
            bits_per_sample: 16,
            sample_format: hound::SampleFormat::Int,
        };
        let mut writer = hound::WavWriter::create(path, spec)
            .with_context(|| format!("create wav {:?}", path))?;
        for &s in &self.samples {
            writer.write_sample(s).context("write sample")?;
        }
        writer.finalize().context("finalize wav")?;
        Ok(())
    }
}

/// Прочитать максимум `out.len()` сэмплов (i16 LE) с любого `Read` в `out`.
/// Возвращает количество прочитанных сэмплов. 0 = EOF.
pub fn read_samples_le(reader: &mut impl Read, out: &mut [i16]) -> Result<usize> {
    // Читаем в byte-буфер, потом конвертируем в i16.
    let byte_len = out.len() * 2;
    let mut bytes = vec![0u8; byte_len];
    let mut total = 0usize;
    while total < byte_len {
        match reader.read(&mut bytes[total..])? {
            0 => break, // EOF
            n => total += n,
        }
    }
    // total — байт. Сэмплов = total / 2, неполный последний байт игнорируем.
    let sample_count = total / 2;
    for i in 0..sample_count {
        let lo = bytes[i * 2] as i16;
        let hi = bytes[i * 2 + 1] as i16;
        out[i] = (hi << 8) | (lo & 0xff);
    }
    Ok(sample_count)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn buffer_accumulates_samples() {
        let mut b = AudioBuffer::new();
        assert_eq!(b.len(), 0);
        b.extend(&[1, 2, 3]);
        b.extend(&[4, 5]);
        assert_eq!(b.len(), 5);
    }

    #[test]
    fn duration_ms_matches_expected() {
        let mut b = AudioBuffer::new();
        b.extend(&vec![0i16; 16_000]); // 1 секунда @16kHz
        assert_eq!(b.duration_ms(16_000), 1000);
    }

    #[test]
    fn write_wav_creates_valid_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("out.wav");
        let mut b = AudioBuffer::new();
        b.extend(&vec![100i16; 16_000]);
        b.write_wav(&path, 16_000).unwrap();

        // Прочитаем обратно — должно быть 16_000 сэмплов с value 100.
        let reader = hound::WavReader::open(&path).unwrap();
        let spec = reader.spec();
        assert_eq!(spec.channels, 1);
        assert_eq!(spec.sample_rate, 16_000);
        assert_eq!(spec.bits_per_sample, 16);
        let samples: Vec<i16> = reader.into_samples().map(|s| s.unwrap()).collect();
        assert_eq!(samples.len(), 16_000);
        assert!(samples.iter().all(|&s| s == 100));
    }

    #[test]
    fn read_samples_le_parses_bytes() {
        // Два сэмпла: 0x0001 (1) и 0xFFFF (-1) в little-endian.
        let bytes = vec![0x01, 0x00, 0xFF, 0xFF];
        let mut cursor = Cursor::new(bytes);
        let mut out = [0i16; 2];
        let n = read_samples_le(&mut cursor, &mut out).unwrap();
        assert_eq!(n, 2);
        assert_eq!(out[0], 1);
        assert_eq!(out[1], -1);
    }

    #[test]
    fn read_samples_le_handles_eof() {
        let bytes = vec![0x01, 0x00]; // только один сэмпл
        let mut cursor = Cursor::new(bytes);
        let mut out = [0i16; 4];
        let n = read_samples_le(&mut cursor, &mut out).unwrap();
        assert_eq!(n, 1);
        assert_eq!(out[0], 1);
    }

    #[test]
    fn end_session_with_partial_chunk_includes_all_samples() {
        // 1500 семплов — меньше 100ms при 16kHz (100ms = 1600 семплов).
        // Проверяем что write_wav → read_wav сохраняет ровно 1500 семплов.
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("partial.wav");
        let mut b = AudioBuffer::new();
        b.extend(&vec![42i16; 1500]);
        assert_eq!(b.len(), 1500);
        b.write_wav(&path, 16_000).unwrap();

        let reader = hound::WavReader::open(&path).unwrap();
        let samples: Vec<i16> = reader.into_samples().map(|s: hound::Result<i16>| s.unwrap()).collect();
        assert_eq!(samples.len(), 1500);
        assert!(samples.iter().all(|&s| s == 42));
    }
}
