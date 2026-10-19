// Claude Code 钩子：把会话事件追加到 ~/.desk-pet/events.jsonl，供桌宠读取。
// 从 stdin 读钩子输入 JSON；任何异常都静默退出（exit 0），绝不影响会话本身。
import { appendFileSync, mkdirSync, openSync, readSync, fstatSync, closeSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, join } from 'node:path';

const DIR = join(homedir(), '.desk-pet');
const FILE = join(DIR, 'events.jsonl');

// 只要最后一段助手文字，当作「完成了什么」的摘要；transcript 可能很大，只读尾部 256KB
function lastAssistantText(path) {
  try {
    const fd = openSync(path, 'r');
    const size = fstatSync(fd).size;
    const len = Math.min(size, 256 * 1024);
    const buf = Buffer.alloc(len);
    readSync(fd, buf, 0, len, size - len);
    closeSync(fd);
    const lines = buf.toString('utf8').split('\n').reverse();
    for (const line of lines) {
      if (!line.includes('"assistant"')) continue;
      try {
        const o = JSON.parse(line);
        const content = o.message && o.message.content;
        const parts = Array.isArray(content) ? content : [];
        const text = parts.filter((c) => c && c.type === 'text').map((c) => c.text).join(' ').trim();
        if (text) return text;
      } catch (e) { /* 半截行 */ }
    }
  } catch (e) { /* 读不到就算了 */ }
  return '';
}

const oneLine = (s, n) => String(s || '').replace(/\s+/g, ' ').replace(/[#*`>|]/g, '').trim().slice(0, n);

let raw = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (d) => { raw += d; });
process.stdin.on('end', () => {
  try {
    // 去掉 BOM：PowerShell 管道进来的输入会带
    const text = raw.replace(/^﻿/, '').trim();
    const input = text ? JSON.parse(text) : {};
    const event = input.hook_event_name || process.argv[2] || 'Unknown';
    const cwd = input.cwd || '';
    const out = {
      ts: Date.now(),
      event,
      session: String(input.session_id || ''),
      project: basename(cwd) || '?',
      cwd,
    };
    if (event === 'Notification') {
      out.kind = input.notification_type || '';
      out.text = oneLine(input.message, 120);
    } else if (event === 'Stop' || event === 'SubagentStop') {
      const path = event === 'SubagentStop' ? input.agent_transcript_path || input.transcript_path : input.transcript_path;
      out.text = oneLine(input.last_assistant_message || (path ? lastAssistantText(path) : ''), 120);
      if (event === 'SubagentStop') out.agent = input.agent_type || '';
    } else if (event === 'PostToolUseFailure' || event === 'PermissionDenied' || event === 'StopFailure') {
      out.tool = input.tool_name || '';
      out.text = oneLine(input.error || input.reason || input.message || '', 120);
    }
    mkdirSync(DIR, { recursive: true });
    appendFileSync(FILE, `${JSON.stringify(out)}\n`);
  } catch (e) {
    // 平时静默；设 DESK_PET_DEBUG=1 时把原因打到 stderr，排查用
    if (process.env.DESK_PET_DEBUG) process.stderr.write(`desk-pet hook: ${e && e.stack ? e.stack : e}\n`);
  }
  process.exit(0);
});
