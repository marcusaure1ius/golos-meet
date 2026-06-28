//! VAD-сегментация: режет поток сэмплов (16kHz mono f32) на речевые куски
//! по энергии (RMS). Возвращает диапазоны сэмплов — старт/энд в секундах
//! вычисляет вызывающий как sample/16000. GigaAM сегментов не даёт, поэтому
//! таймкоды берём из позиции куска.

use transcribe_rs::vad::{EnergyVad, Vad};

pub const SAMPLE_RATE: usize = 16_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SpeechRegion {
    pub start_sample: usize,
    pub end_sample: usize,
}

#[derive(Debug, Clone)]
pub struct SegmentConfig {
    pub frame_size: usize,
    /// VAD порог (RMS энергия); подобран эмпирически на 10 встречах
    /// выше шума дальних/шумных микрофонов (~0.003–0.004), но ловит тихую речь
    pub threshold_rms: f32,
    /// Сколько подряд тихих фреймов закрывают речевой регион.
    pub hangover_frames: usize,
    /// Регионы короче этого (в сэмплах) отбрасываем как шум.
    pub min_region_samples: usize,
}

impl Default for SegmentConfig {
    fn default() -> Self {
        Self {
            frame_size: 480,          // 30ms @16kHz
            threshold_rms: 0.005,
            hangover_frames: 15,      // ~450ms тишины закрывает регион
            min_region_samples: 4_800, // 300ms
        }
    }
}

/// Найти речевые регионы. Простая state-machine: вход в речь по первому
/// speech-фрейму, выход — после `hangover_frames` тишины подряд.
pub fn segment_speech(samples: &[f32], cfg: &SegmentConfig) -> Vec<SpeechRegion> {
    let mut vad = EnergyVad::new(cfg.frame_size, cfg.threshold_rms);
    let mut regions = Vec::new();
    let mut in_speech = false;
    let mut region_start = 0usize;
    let mut silence_run = 0usize;
    let mut last_speech_end = 0usize;

    let mut i = 0usize;
    while i + cfg.frame_size <= samples.len() {
        let frame = &samples[i..i + cfg.frame_size];
        let speech = vad.is_speech(frame).unwrap_or(false);
        if speech {
            if !in_speech {
                in_speech = true;
                region_start = i;
            }
            silence_run = 0;
            last_speech_end = i + cfg.frame_size;
        } else if in_speech {
            silence_run += 1;
            if silence_run >= cfg.hangover_frames {
                push_region(&mut regions, region_start, last_speech_end, cfg);
                in_speech = false;
                silence_run = 0;
            }
        }
        i += cfg.frame_size;
    }
    if in_speech {
        push_region(&mut regions, region_start, last_speech_end.max(region_start), cfg);
    }
    regions
}

fn push_region(out: &mut Vec<SpeechRegion>, start: usize, end: usize, cfg: &SegmentConfig) {
    if end > start && end - start >= cfg.min_region_samples {
        out.push(SpeechRegion { start_sample: start, end_sample: end });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(n: usize) -> Vec<f32> { vec![0.5f32; n] }
    fn silence(n: usize) -> Vec<f32> { vec![0.0f32; n] }

    #[test]
    fn pure_silence_yields_no_regions() {
        let s = silence(16_000);
        assert!(segment_speech(&s, &SegmentConfig::default()).is_empty());
    }

    #[test]
    fn single_tone_block_is_one_region() {
        // 1s тона между двумя паузами.
        let mut s = silence(8_000);
        s.extend(tone(16_000));
        s.extend(silence(16_000)); // длинная пауза > hangover закрывает регион
        let r = segment_speech(&s, &SegmentConfig::default());
        assert_eq!(r.len(), 1);
        // старт около 8000 сэмплов (0.5s), с точностью до frame_size
        assert!((r[0].start_sample as i64 - 8_000).abs() <= 480);
        assert!(r[0].end_sample >= 8_000 + 16_000);
    }

    #[test]
    fn two_blocks_split_by_long_silence() {
        let mut s = tone(16_000);
        s.extend(silence(16_000)); // пауза 1s > hangover
        s.extend(tone(16_000));
        s.extend(silence(8_000));
        let r = segment_speech(&s, &SegmentConfig::default());
        assert_eq!(r.len(), 2);
        assert!(r[0].end_sample <= r[1].start_sample);
    }

    #[test]
    fn region_shorter_than_min_is_dropped() {
        let cfg = SegmentConfig::default();
        let mut s = silence(8_000);
        s.extend(tone(2_000)); // 125ms < min 300ms
        s.extend(silence(16_000));
        assert!(segment_speech(&s, &cfg).is_empty());
    }
}
