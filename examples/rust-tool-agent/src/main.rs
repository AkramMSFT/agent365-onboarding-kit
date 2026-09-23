use agent365_rust_tool_agent::{run_agent, HttpModel, OfflineModel, Provider};
use serde_json::json;

fn main() -> std::process::ExitCode {
    match run() {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{error}");
            std::process::ExitCode::FAILURE
        }
    }
}
fn run() -> Result<(), String> {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("--help") {
        println!("cargo run --locked -- [--mock|--live] [text/prompt]\nDefault is offline. Live mode uses MODEL_PROVIDER and its provider-specific process environment key.");
        return Ok(());
    }
    let mode = if args.first().is_some_and(|arg| arg.starts_with("--")) {
        args.remove(0)
    } else {
        "--mock".into()
    };
    if mode != "--mock" && mode != "--live" {
        return Err("use --mock or --live".into());
    }
    let prompt = if args.is_empty() {
        "Hello Agent 365".into()
    } else {
        args.join(" ")
    };
    if mode == "--live" {
        let provider = Provider::from_environment(|key| std::env::var(key).ok())?;
        println!("{}", run_agent(&mut HttpModel::new(provider)?, &prompt, 6)?);
    } else {
        let mut model = OfflineModel::new(&prompt);
        let output = run_agent(&mut model, &prompt, 6)?;
        println!(
            "{}",
            json!({"mode":"mock","aiInference":false,"output":output,"modelRequests":model.requests})
        );
    }
    Ok(())
}
