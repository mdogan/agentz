//! What an agent is doing, for the session list: the last tool it called,
//! read from its transcript, e.g. the command it runs or the file it edits.

use std::path::Path;

use serde_json::Value;

/// The last tool an agent called.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct Action {
    pub kind: ActionKind,
    /// What it works on, on one line: the command (or what Claude says it
    /// does), the file's name, what it looks for, the sub-agent's task. For
    /// `Tool`, the tool's name.
    pub detail: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum ActionKind {
    /// Runs a command.
    Command,
    /// Reads a file.
    Read,
    /// Changes, writes or deletes a file.
    Edit,
    /// Looks for files, or for text in them.
    Search,
    /// Searches the web or reads a page.
    Web,
    /// Gives work to a sub-agent.
    Agent,
    /// Any other tool.
    Tool,
}

use ActionKind::*;

/// The longest `detail`. The list shows less of it anyway.
const MAX_DETAIL: usize = 120;

impl Action {
    /// None when there is nothing to show.
    fn new(kind: ActionKind, detail: &str) -> Option<Action> {
        let detail = one_line(detail);
        (!detail.is_empty()).then_some(Action { kind, detail })
    }
}

/// The last tool call in a Claude `assistant` transcript line.
pub fn claude(v: &Value) -> Option<Action> {
    let blocks = v["message"]["content"].as_array()?;
    let block = blocks.iter().rev().find(|b| b["type"] == "tool_use")?;
    let name = block["name"].as_str()?;
    let field = |key: &str| block["input"][key].as_str().unwrap_or_default();
    let action = match name {
        // What Claude says a command does reads better than a long command.
        "Bash" => Action::new(Command, or(field("description"), field("command"))),
        "Read" => file(Read, field("file_path")),
        "Edit" | "MultiEdit" | "Write" => file(Edit, field("file_path")),
        "NotebookEdit" => file(Edit, field("notebook_path")),
        "Grep" | "Glob" => Action::new(Search, field("pattern")),
        "WebSearch" => Action::new(Web, field("query")),
        "WebFetch" => Action::new(Web, without_scheme(field("url"))),
        "Agent" | "Task" => Action::new(Agent, or(field("description"), field("subagent_type"))),
        "Skill" => Action::new(Tool, field("skill")),
        _ => None,
    };
    action.or_else(|| tool(name))
}

/// The tool call in a Codex `response_item` payload. None for one that only
/// waits for an earlier call, like reading more output of a command: the
/// earlier one still tells what it does.
pub fn codex(payload: &Value) -> Option<Action> {
    match payload["type"].as_str()? {
        "function_call" => {
            let name = payload["name"].as_str()?;
            let args = payload["arguments"]
                .as_str()
                .and_then(|a| serde_json::from_str(a).ok())
                .unwrap_or(Value::Null);
            codex_tool(name, &args)
        }
        "custom_tool_call" => {
            let input = payload["input"].as_str().unwrap_or_default();
            match payload["name"].as_str()? {
                "apply_patch" => patch(input),
                "exec" => code(input),
                name => tool(name),
            }
        }
        "local_shell_call" => Action::new(Command, &command(&payload["action"]["command"])),
        "web_search_call" => {
            let a = &payload["action"];
            Action::new(Web, or(text(&a["query"]), text(&a["url"])))
                .or_else(|| Action::new(Web, "the web"))
        }
        _ => None,
    }
}

/// Codex's tools that only wait for an earlier call.
fn waits(name: &str) -> bool {
    matches!(name, "write_stdin" | "wait")
}

fn codex_tool(name: &str, args: &Value) -> Option<Action> {
    if waits(name) {
        return None;
    }
    let field = |key: &str| text(&args[key]);
    let action = match name {
        "exec_command" => Action::new(Command, field("cmd")),
        "shell" | "container.exec" => Action::new(Command, &command(&args["command"])),
        "view_image" => file(Read, field("path")),
        "spawn_agent" => Action::new(Agent, or(field("task_name"), field("agent_type"))),
        _ => None,
    };
    action.or_else(|| tool(name))
}

/// Codex's code mode runs JavaScript that calls its tools, e.g. `const r =
/// await tools.exec_command({cmd:"git status"})`. The first tool it calls
/// tells what it does, and a patch in it is an edit.
fn code(input: &str) -> Option<Action> {
    if let Some(action) = patch(input) {
        return Some(action);
    }
    let mut rest = input;
    while let Some(i) = rest.find("tools.") {
        rest = &rest[i + "tools.".len()..];
        let end = rest
            .find(|c: char| !(c.is_ascii_alphanumeric() || c == '_'))
            .unwrap_or(rest.len());
        let (name, args) = rest.split_at(end);
        if name.is_empty() || !args.starts_with('(') || waits(name) {
            continue;
        }
        let action = match name {
            "exec_command" => js_string(args, "cmd").and_then(|c| Action::new(Command, &c)),
            "web__run" => js_string(args, "q")
                .and_then(|q| Action::new(Web, &q))
                .or_else(|| Action::new(Web, "the web")),
            _ => None,
        };
        return action.or_else(|| codex_tool(name, &Value::Null));
    }
    None
}

/// The first file a patch (`*** Begin Patch`) changes.
fn patch(input: &str) -> Option<Action> {
    let (i, marker) = ["*** Update File: ", "*** Add File: ", "*** Delete File: "]
        .into_iter()
        .filter_map(|m| input.find(m).map(|i| (i, m)))
        .min()?;
    let rest = &input[i + marker.len()..];
    // In JavaScript the patch is in a string, with `\n` for its newlines.
    let end = rest.find(['\n', '\\', '"']).unwrap_or(rest.len());
    file(Edit, &rest[..end])
}

/// The string after `key:` (or `"key":`) in JavaScript, when it is in
/// double quotes, as JSON writes it.
fn js_string(code: &str, key: &str) -> Option<String> {
    let mut rest = code;
    loop {
        let i = rest.find(key)?;
        let starts_word = rest[..i]
            .chars()
            .next_back()
            .is_none_or(|c| !(c.is_ascii_alphanumeric() || c == '_'));
        rest = &rest[i + key.len()..];
        if !starts_word {
            continue;
        }
        let after = rest.strip_prefix('"').unwrap_or(rest).trim_start();
        let Some(value) = after.strip_prefix(':').map(str::trim_start) else {
            continue;
        };
        if value.starts_with('"') {
            return serde_json::Deserializer::from_str(value)
                .into_iter::<String>()
                .next()?
                .ok();
        }
    }
}

/// A command given as a string, or as arguments like `["bash", "-lc",
/// "make test"]`.
fn command(v: &Value) -> String {
    if let Some(s) = v.as_str() {
        return s.to_string();
    }
    let args: Vec<&str> = v
        .as_array()
        .map(|a| a.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    match args.as_slice() {
        [_, "-c" | "-lc", script] => script.to_string(),
        _ => args.join(" "),
    }
}

/// An action on a file, shown by the file's name.
fn file(kind: ActionKind, path: &str) -> Option<Action> {
    let name = Path::new(path.trim()).file_name()?.to_str()?;
    Action::new(kind, name)
}

/// Any other tool, by its name. An MCP tool (`mcp__<server>__<tool>`) by the
/// tool's own name.
fn tool(name: &str) -> Option<Action> {
    let name = if name.starts_with("mcp__") {
        name.rsplit("__").next().unwrap_or(name)
    } else {
        name
    };
    Action::new(Tool, name)
}

fn text(v: &Value) -> &str {
    v.as_str().unwrap_or_default()
}

/// `a`, or `b` when `a` is blank.
fn or<'a>(a: &'a str, b: &'a str) -> &'a str {
    if a.trim().is_empty() { b } else { a }
}

fn without_scheme(url: &str) -> &str {
    url.split_once("://").map_or(url, |(_, rest)| rest)
}

/// `s` on one line, cut to `MAX_DETAIL` characters with `…`.
fn one_line(s: &str) -> String {
    let s = s.split_whitespace().collect::<Vec<_>>().join(" ");
    if s.chars().count() <= MAX_DETAIL {
        return s;
    }
    let mut cut: String = s.chars().take(MAX_DETAIL - 1).collect();
    cut.push('…');
    cut
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn act(kind: ActionKind, detail: &str) -> Option<Action> {
        Some(Action {
            kind,
            detail: detail.into(),
        })
    }

    fn claude_call(name: &str, input: Value) -> Option<Action> {
        claude(&json!({
            "type": "assistant",
            "message": {"content": [
                {"type": "text", "text": "Let me look."},
                {"type": "tool_use", "name": name, "input": input},
            ]},
        }))
    }

    #[test]
    fn claude_tools() {
        assert_eq!(
            claude_call(
                "Bash",
                json!({"command": "make test", "description": "Run the tests"})
            ),
            act(Command, "Run the tests")
        );
        assert_eq!(
            claude_call(
                "Bash",
                json!({"command": "make\n  test", "description": " "})
            ),
            act(Command, "make test")
        );
        assert_eq!(
            claude_call("Edit", json!({"file_path": "/w/src/Sidebar.swift"})),
            act(Edit, "Sidebar.swift")
        );
        assert_eq!(
            claude_call("Read", json!({"file_path": "/w/README.md"})),
            act(Read, "README.md")
        );
        assert_eq!(
            claude_call("Grep", json!({"pattern": "fn main"})),
            act(Search, "fn main")
        );
        assert_eq!(
            claude_call("WebFetch", json!({"url": "https://ghostty.org/docs"})),
            act(Web, "ghostty.org/docs")
        );
        assert_eq!(
            claude_call(
                "Agent",
                json!({"description": "Find callers", "prompt": "..."})
            ),
            act(Agent, "Find callers")
        );
        assert_eq!(
            claude_call("mcp__context7__query-docs", json!({})),
            act(Tool, "query-docs")
        );
        assert_eq!(claude_call("TodoWrite", json!({})), act(Tool, "TodoWrite"));
        // Without what it works on, by the tool's name.
        assert_eq!(claude_call("Read", json!({})), act(Tool, "Read"));
        assert_eq!(
            claude(&json!({"message": {"content": [{"type": "text", "text": "Done."}]}})),
            None
        );
    }

    #[test]
    fn codex_tools() {
        let call = |name: &str, args: Value| {
            codex(&json!({"type": "function_call", "name": name, "arguments": args.to_string()}))
        };
        assert_eq!(
            call(
                "exec_command",
                json!({"cmd": "cargo test", "workdir": "/w"})
            ),
            act(Command, "cargo test")
        );
        assert_eq!(
            call("shell", json!({"command": ["bash", "-lc", "ls -la"]})),
            act(Command, "ls -la")
        );
        assert_eq!(
            call("shell", json!({"command": ["git", "status"]})),
            act(Command, "git status")
        );
        assert_eq!(call("write_stdin", json!({"session_id": 1})), None);
        assert_eq!(call("wait", json!({})), None);
        assert_eq!(
            call("spawn_agent", json!({"task_name": "audit", "message": "x"})),
            act(Agent, "audit")
        );
        assert_eq!(
            call("update_plan", json!({"plan": []})),
            act(Tool, "update_plan")
        );
        assert_eq!(
            codex(&json!({
                "type": "custom_tool_call",
                "name": "apply_patch",
                "input": "*** Begin Patch\n*** Update File: core/src/lib.rs\n@@\n-a\n+b\n*** End Patch",
            })),
            act(Edit, "lib.rs")
        );
        assert_eq!(
            codex(
                &json!({"type": "local_shell_call", "action": {"command": ["zsh", "-c", "pwd"]}})
            ),
            act(Command, "pwd")
        );
        assert_eq!(
            codex(
                &json!({"type": "web_search_call", "action": {"type": "search", "query": "uniffi enums"}})
            ),
            act(Web, "uniffi enums")
        );
        assert_eq!(
            codex(&json!({"type": "web_search_call", "action": {"type": "open_page"}})),
            act(Web, "the web")
        );
        assert_eq!(
            codex(&json!({"type": "message", "role": "assistant"})),
            None
        );
    }

    #[test]
    fn codex_code_mode() {
        let exec = |input: &str| {
            codex(&json!({"type": "custom_tool_call", "name": "exec", "input": input}))
        };
        assert_eq!(
            exec(
                r#"const r = await tools.exec_command({"cmd":"rg -n \"x\" src","workdir":"/w"});"#
            ),
            act(Command, r#"rg -n "x" src"#)
        );
        assert_eq!(
            exec(r#"text(await tools.exec_command({cmd:"git status", max_output_tokens: 100}));"#),
            act(Command, "git status")
        );
        // Waiting for a command still running: it still runs that command.
        assert_eq!(
            exec(r#"const r = await tools.write_stdin({"session_id":5,"chars":""});"#),
            None
        );
        assert_eq!(
            exec(
                r#"const patch = "*** Begin Patch\n*** Add File: /w/notes.md\n+hi\n*** End Patch"; text(await tools.apply_patch(patch));"#
            ),
            act(Edit, "notes.md")
        );
        assert_eq!(
            exec(r#"const r = await tools.web__run({search_query:[{q:"rfc 9110"}]}); text(r);"#),
            act(Web, "rfc 9110")
        );
        assert_eq!(
            exec(r#"const r = await tools.mcp__linear__get_issue({id:"RED-1"});"#),
            act(Tool, "get_issue")
        );
        // A command in single quotes is not read.
        assert_eq!(
            exec(r#"await tools.exec_command({cmd:'ls'})"#),
            act(Tool, "exec_command")
        );
        assert_eq!(exec("text(JSON.stringify(results));"), None);
    }

    #[test]
    fn long_details_are_cut() {
        let long = "x ".repeat(200);
        let action = Action::new(Command, &long).unwrap();
        assert_eq!(action.detail.chars().count(), MAX_DETAIL);
        assert!(action.detail.ends_with('…'));
        assert_eq!(Action::new(Command, " \n "), None);
    }
}
