use golos_asr::protocol::{Request, Response};

#[test]
fn request_load_round_trip() {
    let r = Request::Load { id: 1, model_path: "/tmp/model".into() };
    let json = serde_json::to_string(&r).unwrap();
    assert!(json.contains(r#""type":"load""#));
    assert!(json.contains(r#""id":1"#));
    assert!(json.contains(r#""/tmp/model""#));
    let back: Request = serde_json::from_str(&json).unwrap();
    assert_eq!(r, back);
}

#[test]
fn request_begin_session_round_trip() {
    let r = Request::BeginSession { id: 5 };
    let json = serde_json::to_string(&r).unwrap();
    assert!(json.contains(r#""type":"begin_session""#));
    assert!(json.contains(r#""id":5"#));
    let back: Request = serde_json::from_str(&json).unwrap();
    assert_eq!(r, back);
}

#[test]
fn response_final_round_trip() {
    let r = Response::Final {
        id: 7,
        text: "привет мир".into(),
        duration_ms: 1234,
    };
    let json = serde_json::to_string(&r).unwrap();
    assert!(json.contains(r#""type":"final""#));
    assert!(json.contains(r#""id":7"#));
    assert!(json.contains("1234"));
}

#[test]
fn response_error_serializes_with_kind_and_message() {
    let r = Response::Error {
        id: Some(3),
        kind: "model_not_loaded".into(),
        message: "call load first".into(),
    };
    let json = serde_json::to_string(&r).unwrap();
    assert!(json.contains(r#""type":"error""#));
    assert!(json.contains(r#""kind":"model_not_loaded""#));
}

#[test]
fn response_error_id_none_serializes() {
    let r = Response::Error {
        id: None,
        kind: "bad_request".into(),
        message: "invalid json".into(),
    };
    let json = serde_json::to_string(&r).unwrap();
    assert!(json.contains(r#""type":"error""#));
    assert!(json.contains(r#""id":null"#));
}

#[test]
fn unknown_request_type_returns_err() {
    let bad = r#"{"type":"unknown_op"}"#;
    let parsed: Result<Request, _> = serde_json::from_str(bad);
    assert!(parsed.is_err());
}

#[test]
fn end_session_with_samples_total_round_trip() {
    let req = Request::EndSession { id: 2, samples_total: 32_000 };
    let json = serde_json::to_string(&req).unwrap();
    assert!(json.contains("\"samples_total\":32000"));
    assert!(json.contains("\"id\":2"));
    let parsed: Request = serde_json::from_str(&json).unwrap();
    assert_eq!(parsed, req);
}

#[test]
fn request_id_round_trip() {
    let req = Request::BeginSession { id: 42 };
    let json = serde_json::to_string(&req).unwrap();
    assert!(json.contains("\"id\":42"));
}

#[test]
fn response_carries_id() {
    let resp = Response::SessionStarted { id: 42 };
    let json = serde_json::to_string(&resp).unwrap();
    assert!(json.contains("\"id\":42"));
}
