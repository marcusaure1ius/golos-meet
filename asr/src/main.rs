//! Точка входа sidecar. Аргументы: `--audio-path <path>`. Читает stdin построчно,
//! audio-path — открывает путь как FIFO/файл и читает Int16 LE сэмплы.
//! Пишет в stdout JSON-lines.
//!
//! Почему path а не fd: macOS `Process` (NSTask) использует `posix_spawn` с
//! `POSIX_SPAWN_CLOEXEC_DEFAULT`, который закрывает все fd не из явного
//! `addinherit_np` списка — даже если родитель снял `FD_CLOEXEC`. Process не
//! даёт доступа к этому списку, поэтому fd 3 в child всегда оказывался невалидным.
//! Передача path обходит это: child открывает FIFO сам.

use anyhow::{Context, Result};
use clap::Parser;
use golos_asr::audio::read_samples_le;
use golos_asr::protocol::{Request, Response};
use golos_asr::session::Session;
use std::fs::File;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Mutex};
use std::thread;

#[derive(Parser, Debug)]
#[command(version, about = "GigaAM-v3 transcription sidecar for golos.app")]
struct Args {
    /// Путь к FIFO с бинарным потоком PCM (Int16 LE, 16kHz mono).
    #[arg(long)]
    audio_path: PathBuf,
}

const AUDIO_CHUNK_SAMPLES: usize = 1600; // ~100ms @16kHz
const _: () = assert!(AUDIO_CHUNK_SAMPLES > 0);

fn main() -> Result<()> {
    init_logging();
    let args = Args::parse();
    tracing::info!("golos-asr starting (audio_path={:?})", args.audio_path);

    // 1. Стандартный output — наш канал ответов. Заворачиваем в Mutex,
    //    чтобы оба треда (main и audio-reader) могли писать.
    let stdout = Arc::new(Mutex::new(std::io::stdout()));
    write_response(&stdout, &Response::Hello {
        version: env!("CARGO_PKG_VERSION").into(),
    })?;

    // 2. Сессия + общий ресурс между audio thread и control loop.
    let session = Arc::new(Mutex::new(Session::new()?));
    let samples_read = Arc::new(std::sync::atomic::AtomicU64::new(0));

    // Канал, куда audio thread шлёт уведомление каждый раз, когда счётчик увеличился.
    let (samples_tx, samples_rx) = channel::<u64>();

    // 3. Отдельный тред читает audio-path (FIFO) и пушит сэмплы в Session::feed_samples.
    let audio_session = Arc::clone(&session);
    let audio_counter = Arc::clone(&samples_read);
    let audio_path = args.audio_path.clone();
    thread::spawn(move || {
        if let Err(e) = audio_reader_loop(&audio_path, audio_session, audio_counter, samples_tx) {
            tracing::error!("audio reader exited with error: {:#}", e);
        }
    });

    // 4. Основной цикл — читаем stdin построчно, обрабатываем control messages.
    let stdin = std::io::stdin();
    let reader = BufReader::new(stdin.lock());
    for line in reader.lines() {
        let line = line.context("read stdin line")?;
        if line.trim().is_empty() { continue; }

        let req: Request = match serde_json::from_str(&line) {
            Ok(r) => r,
            Err(e) => {
                write_response(&stdout, &Response::Error {
                    id: None,
                    kind: "bad_request".into(),
                    message: format!("invalid JSON: {}", e),
                })?;
                continue;
            }
        };

        let is_shutdown = matches!(req, Request::Shutdown { .. });

        // Если BeginSession — сбрасываем счётчик сэмплов перед новой сессией.
        if matches!(req, Request::BeginSession { .. }) {
            samples_read.store(0, std::sync::atomic::Ordering::SeqCst);
        }

        // Если EndSession — ждём, что audio thread прочитал столько же сэмплов, сколько Swift послал.
        if let Request::EndSession { id, samples_total } = req {
            let deadline = std::time::Instant::now() + std::time::Duration::from_millis(500);
            while samples_read.load(std::sync::atomic::Ordering::SeqCst) < samples_total {
                let remaining = deadline.saturating_duration_since(std::time::Instant::now());
                if remaining.is_zero() {
                    tracing::warn!(
                        "EndSession: timed out waiting for samples; have={}, want={}",
                        samples_read.load(std::sync::atomic::Ordering::SeqCst),
                        samples_total
                    );
                    break;
                }
                match samples_rx.recv_timeout(remaining) {
                    Ok(_) => continue,
                    Err(_) => break,
                }
            }
            let resp = {
                let mut s = session.lock().expect("session mutex poisoned");
                s.handle(Request::EndSession { id, samples_total })
            };
            write_response(&stdout, &resp)?;
            continue;
        }

        let resp = {
            let mut s = session.lock().expect("session mutex poisoned");
            s.handle(req)
        };
        write_response(&stdout, &resp)?;
        if is_shutdown { break; }
    }

    tracing::info!("golos-asr exiting");
    Ok(())
}

fn audio_reader_loop(
    path: &std::path::Path,
    session: Arc<Mutex<Session>>,
    counter: Arc<std::sync::atomic::AtomicU64>,
    notify: Sender<u64>,
) -> Result<()> {
    // open(2) на FIFO для чтения блокируется, пока writer (Swift) не откроет свой конец.
    // Swift открывает с O_RDWR, поэтому read-конец сразу становится доступен.
    let mut file = File::open(path)
        .with_context(|| format!("open audio fifo {:?}", path))?;
    tracing::info!("audio fifo opened: {:?}", path);
    let mut buf = vec![0i16; AUDIO_CHUNK_SAMPLES];
    loop {
        let n = read_samples_le(&mut file, &mut buf).context("read audio fifo")?;
        if n == 0 {
            tracing::info!("audio fifo EOF");
            return Ok(());
        }
        {
            let mut s = session.lock().expect("session mutex poisoned");
            s.feed_samples(&buf[..n]);
        }
        let total = counter.fetch_add(n as u64, std::sync::atomic::Ordering::SeqCst) + n as u64;
        let _ = notify.send(total); // если receiver dropped — control loop уже не ждёт.
    }
}

fn write_response(
    stdout: &Arc<Mutex<std::io::Stdout>>,
    resp: &Response,
) -> Result<()> {
    let line = resp.to_line();
    let mut out = stdout.lock().expect("stdout mutex poisoned");
    out.write_all(line.as_bytes()).context("write stdout")?;
    out.flush().context("flush stdout")?;
    Ok(())
}

fn init_logging() {
    use tracing_subscriber::EnvFilter;
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(EnvFilter::try_from_env("GOLOS_ASR_LOG")
            .unwrap_or_else(|_| EnvFilter::new("info")))
        .init();
}

