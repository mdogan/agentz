//! A session's conversation as Markdown, to save to a file or copy: what
//! the user typed, what the agent answered, and a line for each tool it
//! called. Thinking, what the tools returned, and the context the agent
//! adds by itself (AGENTS.md, reminders, command wrappers) are left out.
//!
//! The terminal can't give this when the agent draws on the alternate
//! screen, as Claude's fullscreen mode and Codex do: then the terminal only
//! has the rows on screen.

use std::collections::{HashMap, HashSet, VecDeque};
use std::fs;
use std::io::{BufRead, BufReader, Seek, SeekFrom};
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use crate::action::{self, Action, ActionKind};
use crate::sessions::{Agent, claude_dir, codex_home};

/// One piece of the conversation, in order.
#[derive(Debug, PartialEq)]
enum Part {
    User(String),
    Text(String),
    Tool(Action),
}

/// The conversation of session `id`, or None when its transcript is not
/// there (yet), or `agent` keeps none.
pub fn markdown(agent: Agent, id: &str) -> Option<String> {
    render_file(agent, &transcript_path(agent, id)?)
}

fn render_file(agent: Agent, path: &Path) -> Option<String> {
    let mut markdown = Markdown::default();
    let reader = BufReader::new(fs::File::open(path).ok()?);
    visit_parts(agent, reader, false, |part| markdown.push(agent, part))?;
    Some(markdown.finish())
}

/// A user prompt and the assistant text that followed it. Tool calls are
/// still included in exports, but take no space in the read-only preview.
#[derive(uniffi::Record)]
pub struct PreviewTurn {
    pub prompt: String,
    pub answer: String,
}

#[derive(uniffi::Record)]
pub struct TranscriptPreview {
    pub turns: Vec<PreviewTurn>,
    pub has_older: bool,
}

pub fn preview(agent: Agent, id: &str, count: u32) -> Option<TranscriptPreview> {
    preview_file(agent, &transcript_path(agent, id)?, count as usize)
}

fn preview_file(agent: Agent, path: &Path, count: usize) -> Option<TranscriptPreview> {
    let file = fs::File::open(path).ok()?;
    let len = file.metadata().ok()?.len();
    let mut reader = BufReader::new(file);
    // Most recent exchanges fit in the tail. Only use a partial result when
    // we saw an earlier prompt on the same branch. Otherwise read from the start.
    const TAIL: u64 = 64 * 1024;
    if len > TAIL {
        reader.seek(SeekFrom::Start(len - TAIL)).ok()?;
        reader.skip_until(b'\n').ok()?;
        let result = collect_turns(agent, &mut reader, count, true)?;
        if result.has_older {
            return Some(result);
        }
        reader.rewind().ok()?;
    }
    collect_turns(agent, reader, count, false)
}

fn collect_turns(
    agent: Agent,
    reader: impl BufRead,
    count: usize,
    partial: bool,
) -> Option<TranscriptPreview> {
    let mut turns = VecDeque::new();
    let mut total = 0;
    let mut prompts = 0;
    visit_parts(agent, reader, partial, |part| {
        if matches!(part, Part::Tool(_)) {
            return;
        }
        if matches!(part, Part::User(_)) {
            prompts += 1;
        }
        if matches!(part, Part::User(_)) || total == 0 {
            total += 1;
            if turns.len() == count {
                turns.pop_front();
            }
            if count > 0 {
                turns.push_back(PreviewTurn {
                    prompt: String::new(),
                    answer: String::new(),
                });
            }
        }
        if let Some(turn) = turns.back_mut() {
            match part {
                Part::User(prompt) => turn.prompt = prompt,
                Part::Text(text) => {
                    if !turn.answer.is_empty() {
                        turn.answer.push_str("\n\n");
                    }
                    turn.answer.push_str(&text);
                }
                Part::Tool(_) => {}
            }
        }
    })?;
    Some(TranscriptPreview {
        turns: turns.into(),
        has_older: if partial {
            prompts > count
        } else {
            total > count
        },
    })
}

struct ClaudeRecord {
    parent: Option<String>,
    parts: Vec<Part>,
}

fn visit_parts(
    agent: Agent,
    mut reader: impl BufRead,
    partial: bool,
    mut visit: impl FnMut(Part),
) -> Option<()> {
    let mut line = String::new();
    let mut parts = Vec::new();
    let mut records = Vec::new();
    let mut index = HashMap::new();
    let mut tip = None;
    loop {
        line.clear();
        if reader.read_line(&mut line).ok()? == 0 {
            break;
        }
        let Ok(v) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        match agent {
            Agent::Codex => {
                codex_record(&v, &mut parts);
                parts.drain(..).for_each(&mut visit);
            }
            Agent::Claude => {
                let pos = records.len();
                if let Some(id) = v["uuid"].as_str() {
                    index.insert(id.to_owned(), pos);
                    if (v["type"] == "user" || v["type"] == "assistant") && v["isSidechain"] != true
                    {
                        tip = Some(pos);
                    }
                }
                let mut parts = Vec::new();
                if v["isSidechain"] != true {
                    claude_record(&v, &mut parts);
                }
                let parent = v["parentUuid"]
                    .as_str()
                    .or_else(|| v["logicalParentUuid"].as_str())
                    .map(str::to_owned);
                records.push(ClaudeRecord { parent, parts });
            }
            Agent::Shell | Agent::Git => return None,
        }
    }
    if agent == Agent::Claude {
        let mut kept = HashSet::new();
        if let Some(mut at) = tip {
            loop {
                kept.insert(at);
                let Some(parent) = &records[at].parent else {
                    break;
                };
                match index.get(parent) {
                    Some(&i) if i < at => at = i,
                    _ => {
                        if !partial {
                            kept.extend(0..at);
                        }
                        break;
                    }
                }
            }
        }
        for (i, record) in records.into_iter().enumerate() {
            if (tip.is_none() && !partial) || kept.contains(&i) {
                record.parts.into_iter().for_each(&mut visit);
            }
        }
    }
    Some(())
}

/// Claude: `<claude dir>/projects/<encoded cwd>/<id>.jsonl`. Codex:
/// `<codex home>/sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl`.
fn transcript_path(agent: Agent, id: &str) -> Option<PathBuf> {
    if id.is_empty() || id.contains('/') {
        return None;
    }
    match agent {
        Agent::Claude => {
            let name = format!("{id}.jsonl");
            fs::read_dir(claude_dir()?.join("projects"))
                .ok()?
                .flatten()
                .map(|d| d.path().join(&name))
                .find(|p| p.is_file())
        }
        Agent::Codex => find_file(&codex_home()?.join("sessions"), &format!("-{id}.jsonl")),
        Agent::Shell | Agent::Git => None,
    }
}

fn find_file(dir: &Path, suffix: &str) -> Option<PathBuf> {
    for e in fs::read_dir(dir).ok()?.flatten() {
        let path = e.path();
        if e.file_type().is_ok_and(|t| t.is_dir()) {
            if let Some(found) = find_file(&path, suffix) {
                return Some(found);
            }
        } else if path
            .file_name()
            .and_then(|n| n.to_str())
            .is_some_and(|n| n.ends_with(suffix))
        {
            return Some(path);
        }
    }
    None
}

fn claude_record(v: &Value, parts: &mut Vec<Part>) {
    let content = &v["message"]["content"];
    match v["type"].as_str() {
        // Not what Claude adds by itself, like a compaction's summary.
        Some("user") if v["isMeta"] != true && v["isCompactSummary"] != true => {
            if let Some(text) = user_text(content) {
                parts.push(Part::User(text));
            }
        }
        Some("assistant") => {
            for block in content.as_array().into_iter().flatten() {
                match block["type"].as_str() {
                    Some("text") => push_text(parts, block["text"].as_str()),
                    Some("tool_use") => {
                        let one = json!({ "message": { "content": [block] } });
                        parts.extend(action::claude(&one).map(Part::Tool));
                    }
                    _ => {}
                }
            }
        }
        _ => {}
    }
}

fn codex_record(v: &Value, parts: &mut Vec<Part>) {
    if v["type"] != "response_item" {
        return;
    }
    let p = &v["payload"];
    match (p["type"].as_str(), p["role"].as_str()) {
        (Some("message"), Some("user")) => {
            if let Some(text) = user_text(&p["content"]) {
                parts.push(Part::User(text));
            }
        }
        (Some("message"), Some("assistant")) => {
            for block in p["content"].as_array().into_iter().flatten() {
                if block["type"] == "output_text" {
                    push_text(parts, block["text"].as_str());
                }
            }
        }
        _ => parts.extend(action::codex(p).map(Part::Tool)),
    }
}

/// What the user typed: the message's text, without what the agent added
/// to it. None for a message with nothing else, like a tool's result.
fn user_text(content: &Value) -> Option<String> {
    let texts: Vec<String> = match content {
        Value::String(s) => vec![s.clone()],
        Value::Array(blocks) => blocks
            .iter()
            .filter_map(|b| match b["type"].as_str()? {
                "text" | "input_text" => b["text"].as_str().map(str::to_string),
                "image" | "input_image" => Some("[Image]".to_string()),
                _ => None,
            })
            .collect(),
        _ => return None,
    };
    let typed: Vec<&str> = texts
        .iter()
        .map(|t| t.trim())
        .filter(|t| !t.is_empty() && !added_by_agent(t))
        .collect();
    (!typed.is_empty()).then(|| typed.join("\n\n"))
}

fn added_by_agent(text: &str) -> bool {
    text.starts_with('<') || text.starts_with("# AGENTS.md") || text.starts_with("Caveat:")
}

fn push_text(parts: &mut Vec<Part>, text: Option<&str>) {
    if let Some(t) = text.map(str::trim).filter(|t| !t.is_empty()) {
        parts.push(Part::Text(t.to_string()));
    }
}

/// A `## You` or `## Claude` heading each time the speaker changes; tool
/// calls as list items.
#[derive(Default)]
struct Markdown {
    text: String,
    user: Option<bool>,
    in_list: bool,
}

impl Markdown {
    fn push(&mut self, agent: Agent, part: Part) {
        let user = matches!(part, Part::User(_));
        if self.user != Some(user) {
            if self.in_list {
                self.text.push('\n');
            }
            let name = if user {
                "You"
            } else if agent == Agent::Codex {
                "Codex"
            } else {
                "Claude"
            };
            self.text.push_str(&format!("## {name}\n\n"));
            self.user = Some(user);
            self.in_list = false;
        }
        match part {
            Part::User(text) | Part::Text(text) => {
                if self.in_list {
                    self.text.push('\n');
                }
                self.in_list = false;
                self.text.push_str(&text);
                self.text.push_str("\n\n");
            }
            Part::Tool(action) => {
                self.text
                    .push_str(&format!("- {}: {}\n", label(action.kind), action.detail));
                self.in_list = true;
            }
        }
    }

    fn finish(mut self) -> String {
        self.text.truncate(self.text.trim_end().len());
        self.text.push('\n');
        self.text
    }
}

fn label(kind: ActionKind) -> &'static str {
    match kind {
        ActionKind::Command => "Ran",
        ActionKind::Read => "Read",
        ActionKind::Edit => "Edited",
        ActionKind::Search => "Searched",
        ActionKind::Web => "Web",
        ActionKind::Agent => "Agent",
        ActionKind::Tool => "Tool",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str, text: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "agentz-export-{name}-{}.jsonl",
            uuid::Uuid::new_v4()
        ));
        fs::write(&path, text).unwrap();
        path
    }

    #[test]
    fn claude_conversation_on_the_last_branch() {
        // a → b → c, then a rewind to a: d → e. Plus a sub-agent's line, a
        // reminder Claude added, thinking, and a tool's result.
        let path = temp(
            "claude",
            r#"{"type":"user","uuid":"a","parentUuid":null,"message":{"role":"user","content":"Fix the bug"}}
{"type":"assistant","uuid":"b","parentUuid":"a","message":{"content":[{"type":"thinking","thinking":"hmm"}]}}
{"type":"assistant","uuid":"c","parentUuid":"b","message":{"content":[{"type":"text","text":"Old answer"}]}}
{"type":"attachment","uuid":"x","parentUuid":"a"}
{"type":"assistant","uuid":"d","parentUuid":"x","message":{"content":[{"type":"text","text":"Looking."},{"type":"tool_use","name":"Bash","input":{"command":"cargo test","description":"Run the tests"}}]}}
{"type":"user","uuid":"r","parentUuid":"d","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":"ok"}]}}
{"type":"assistant","uuid":"s","parentUuid":"r","isSidechain":true,"message":{"content":[{"type":"text","text":"Sub-agent"}]}}
{"type":"user","uuid":"m","parentUuid":"r","isMeta":true,"message":{"content":"<system-reminder>x</system-reminder>"}}
{"type":"assistant","uuid":"e","parentUuid":"m","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/repo/src/main.rs"}},{"type":"text","text":"Fixed."}]}}
{"type":"user","uuid":"f","parentUuid":"e","message":{"content":[{"type":"text","text":"<system-reminder>y</system-reminder>"},{"type":"text","text":"Thanks"}]}}
"#,
        );
        let md = render_file(Agent::Claude, &path).unwrap();
        fs::remove_file(&path).ok();
        assert_eq!(
            md,
            "## You\n\nFix the bug\n\n## Claude\n\nLooking.\n\n- Ran: Run the tests\n- Read: main.rs\n\nFixed.\n\n## You\n\nThanks\n"
        );
    }

    #[test]
    fn claude_compaction_that_points_forward() {
        // The compaction's logical parent comes after it; the start stays.
        let path = temp(
            "claude-compact",
            r#"{"type":"user","uuid":"a","parentUuid":null,"message":{"content":"Before"}}
{"type":"system","subtype":"compact_boundary","uuid":"b","parentUuid":null,"logicalParentUuid":"c"}
{"type":"attachment","uuid":"c","parentUuid":"b"}
{"type":"user","uuid":"d","parentUuid":"c","message":{"content":"After"}}
"#,
        );
        let md = render_file(Agent::Claude, &path).unwrap();
        fs::remove_file(&path).ok();
        assert_eq!(md, "## You\n\nBefore\n\nAfter\n");
    }

    #[test]
    fn claude_without_uuids_keeps_every_line() {
        let path = temp(
            "claude-old",
            r#"{"type":"user","message":{"content":"One"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Two"}]}}
"#,
        );
        let md = render_file(Agent::Claude, &path).unwrap();
        fs::remove_file(&path).ok();
        assert_eq!(md, "## You\n\nOne\n\n## Claude\n\nTwo\n");
    }

    #[test]
    fn codex_conversation() {
        let path = temp(
            "codex",
            r##"{"type":"session_meta","payload":{"id":"x","cwd":"/tmp","source":"cli"}}
{"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"rules"}]}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions"}]}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>x</environment_context>"}]}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"List the files"}]}}
{"type":"response_item","payload":{"type":"reasoning","summary":[]}}
{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"ls\",\"-la\"]}"}}
{"type":"response_item","payload":{"type":"function_call_output","output":"a b"}}
{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Two files."}]}}
"##,
        );
        let md = render_file(Agent::Codex, &path).unwrap();
        fs::remove_file(&path).ok();
        assert_eq!(
            md,
            "## You\n\nList the files\n\n## Codex\n\n- Ran: ls -la\n\nTwo files.\n"
        );
    }

    #[test]
    fn preview_reads_the_newest_turns_on_the_active_branch() {
        let rows = r#"{"type":"user","uuid":"a","message":{"content":"First"}}
{"type":"assistant","uuid":"b","parentUuid":"a","message":{"content":[{"type":"text","text":"One"}]}}
{"type":"user","uuid":"c","parentUuid":"b","message":{"content":"Discarded"}}
{"type":"user","uuid":"d","parentUuid":"b","message":{"content":"Second"}}
{"type":"assistant","uuid":"e","parentUuid":"d","message":{"content":[{"type":"text","text":"Two"}]}}"#;
        let path = temp("preview", &format!("{}\n{rows}", " ".repeat(70000)));
        let latest = preview_file(Agent::Claude, &path, 1).unwrap();
        assert!(latest.has_older);
        assert_eq!(latest.turns.len(), 1);
        assert_eq!(latest.turns[0].prompt, "Second");
        assert_eq!(latest.turns[0].answer, "Two");
        let all = preview_file(Agent::Claude, &path, 5).unwrap();
        assert!(!all.has_older);
        assert_eq!(all.turns.len(), 2);
        assert_eq!(all.turns[0].prompt, "First");
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn no_path_for_shells_or_odd_ids() {
        assert!(transcript_path(Agent::Shell, "x").is_none());
        assert!(transcript_path(Agent::Claude, "../x").is_none());
        assert!(transcript_path(Agent::Claude, "").is_none());
    }
}
