//! End-to-end тест: spawn бинарь, send Load+Begin+audio+End, прочитать Final.
//! Требует распакованной модели по `GOLOS_ASR_MODEL_DIR` и fixture wav.

use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};

fn fixture_path(rel: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures").join(rel)
}

fn binary_path() -> PathBuf {
    // cargo test устанавливает CARGO_BIN_EXE_<name> в путь к собранному бинарю.
    PathBuf::from(env!("CARGO_BIN_EXE_golos-asr"))
}

#[test]
fn e2e_transcribes_sample_wav() {
    let model_dir = match std::env::var("GOLOS_ASR_MODEL_DIR") {
        Ok(s) => s,
        Err(_) => { eprintln!("skipping: GOLOS_ASR_MODEL_DIR not set"); return; }
    };
    let wav = fixture_path("sample_ru_short.wav");
    if !wav.exists() {
        eprintln!("skipping: fixture {:?} missing", wav);
        return;
    }

    // 1. Создать pipe для аудио (родитель пишет, ребёнок читает).
    //    На POSIX используем libc::pipe.
    let mut fds: [i32; 2] = [0, 0];
    unsafe {
        let r = libc::pipe(fds.as_mut_ptr());
        assert_eq!(r, 0, "pipe() failed");
    }
    let read_fd = fds[0];
    let write_fd = fds[1];

    // 2. Снимаем CLOEXEC c read_fd, чтобы Process унаследовал его.
    unsafe {
        let flags = libc::fcntl(read_fd, libc::F_GETFD);
        libc::fcntl(read_fd, libc::F_SETFD, flags & !libc::FD_CLOEXEC);
    }

    let mut child = Command::new(binary_path())
        .arg("--audio-fd").arg(read_fd.to_string())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn sidecar");

    let mut stdin = child.stdin.take().unwrap();
    let stdout = child.stdout.take().unwrap();
    let mut reader = BufReader::new(stdout);

    // Закрываем read_fd в родительском процессе (нам он не нужен).
    unsafe { libc::close(read_fd); }

    // 3. Прочитать `hello`.
    let hello = read_line(&mut reader);
    assert!(hello.contains("\"type\":\"hello\""), "hello expected, got: {}", hello);

    // 4. Послать load.
    writeln!(stdin, r#"{{"type":"load","id":1,"model_path":"{}"}}"#, model_dir).unwrap();
    let ready = read_line(&mut reader);
    assert!(ready.contains("\"type\":\"ready\""), "ready expected, got: {}", ready);

    // 5. Begin session.
    writeln!(stdin, r#"{{"type":"begin_session","id":2}}"#).unwrap();
    let started = read_line(&mut reader);
    assert!(started.contains("\"type\":\"session_started\""), "session_started expected, got: {}", started);

    // 6. Прокачать в audio-pipe содержимое wav (только PCM-data, skip header).
    let mut wav_reader = hound::WavReader::open(&wav).expect("open wav fixture");
    assert_eq!(wav_reader.spec().sample_rate, 16_000);
    assert_eq!(wav_reader.spec().channels, 1);
    let samples: Vec<i16> = wav_reader.samples::<i16>().map(|s| s.unwrap()).collect();
    let bytes: Vec<u8> = samples.iter().flat_map(|&s| s.to_le_bytes()).collect();

    let mut audio_writer = unsafe { std::fs::File::from_raw_fd(write_fd) };
    audio_writer.write_all(&bytes).expect("write audio");
    audio_writer.flush().expect("flush audio");
    drop(audio_writer); // закрываем write end

    // 7. End session, читаем final.
    let samples_total = samples.len() as u64;
    writeln!(stdin, r#"{{"type":"end_session","id":3,"samples_total":{}}}"#, samples_total).unwrap();
    let final_line = read_line(&mut reader);
    assert!(final_line.contains("\"type\":\"final\""), "final expected, got: {}", final_line);
    let lower = final_line.to_lowercase();
    assert!(
        lower.contains("привет") || lower.contains("тестов") || lower.contains("запис"),
        "expected one of recognised tokens, got: {}", final_line
    );

    // 8. Shutdown.
    writeln!(stdin, r#"{{"type":"shutdown","id":4}}"#).unwrap();
    drop(stdin);
    let status = child.wait().expect("child waited");
    assert!(status.success(), "sidecar exit was {:?}", status);
}

fn read_line(reader: &mut impl BufRead) -> String {
    let mut s = String::new();
    reader.read_line(&mut s).expect("read line");
    s
}

use std::os::fd::FromRawFd;
