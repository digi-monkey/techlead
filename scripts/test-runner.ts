/**
 * VA Auto-Pilot acceptance test runner.
 * Usage: npx tsx scripts/test-runner.ts --flow test-flows/feature-smoke.yaml
 * Usage: npx tsx scripts/test-runner.ts --all
 */

import fs from 'node:fs';
import path from 'node:path';
import { parse as parseYaml } from 'yaml';

type Assertion = Record<string, unknown>;

interface Turn {
  send: string;
  assert?: {
    must?: Assertion[];
    should?: Assertion[];
  };
}

interface Flow {
  name: string;
  session: 'new' | string;
  turns: Turn[];
}

interface TestFile {
  name: string;
  preconditions?: string[];
  flows: Flow[];
}

interface ToolCall {
  toolName?: string;
  name?: string;
  args?: Record<string, unknown>;
}

interface ChatResponse {
  sessionId: string;
  response: string;
  metadata: {
    toolCalls?: ToolCall[];
  };
}

interface AssertionResult {
  level: 'must' | 'should';
  passed: boolean;
  assertion: Assertion;
  details: string;
}

interface FlowResult {
  name: string;
  sessionId: string;
  assertions: AssertionResult[];
}

interface RunResult {
  name: string;
  timestamp: string;
  summary: {
    mustTotal: number;
    mustPassed: number;
    shouldTotal: number;
    shouldPassed: number;
    overallPass: boolean;
  };
  flows: FlowResult[];
}

const BASE_URL = process.env.TEST_BASE_URL ?? 'http://localhost:3000';
const API_KEY = process.env.TEST_API_KEY ?? '';
const SETUP_ENDPOINT = '/api/debug/setup';
const CHAT_ENDPOINT = '/api/debug/chat';
const RESULTS_DIR = path.resolve(
  process.env.TEST_RESULTS_DIR ?? 'docs/quality/query-tests/results'
);

function authHeaders(): Record<string, string> {
  if (!API_KEY) return {};
  return { Authorization: `Bearer ${API_KEY}` };
}

async function createSession(): Promise<string> {
  const res = await fetch(`${BASE_URL}${SETUP_ENDPOINT}`, {
    method: 'POST',
    headers: authHeaders(),
  });

  if (!res.ok) {
    throw new Error(`setup failed (${res.status}): ${await res.text()}`);
  }

  const data = (await res.json()) as { sessionId: string };
  return data.sessionId;
}

async function sendMessage(message: string, sessionId?: string): Promise<ChatResponse> {
  const payload: Record<string, string> = { message };
  if (sessionId) payload.sessionId = sessionId;

  const res = await fetch(`${BASE_URL}${CHAT_ENDPOINT}`, {
    method: 'POST',
    headers: { ...authHeaders(), 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  });

  if (!res.ok) {
    throw new Error(`chat failed (${res.status}): ${await res.text()}`);
  }

  return (await res.json()) as ChatResponse;
}

function toolName(call: ToolCall): string {
  return call.toolName ?? call.name ?? '';
}

function evaluateAssertion(
  assertion: Assertion,
  response: string,
  toolCalls: ToolCall[]
): AssertionResult {
  const [[type, value]] = Object.entries(assertion);

  switch (type) {
    case 'tool_called': {
      const name = String(value);
      const passed = toolCalls.some((call) => toolName(call) === name);
      return result(assertion, passed, `expected tool '${name}' to be called`);
    }

    case 'tool_not_called': {
      const name = String(value);
      const passed = toolCalls.every((call) => toolName(call) !== name);
      return result(assertion, passed, `expected tool '${name}' not to be called`);
    }

    case 'response_contains': {
      const terms = toStringArray(value);
      const missing = terms.filter((term) => !response.includes(term));
      return result(
        assertion,
        missing.length === 0,
        missing.length === 0 ? 'all terms found' : `missing: ${missing.join(', ')}`
      );
    }

    case 'response_contains_any': {
      const terms = toStringArray(value);
      const matched = terms.filter((term) => response.includes(term));
      return result(
        assertion,
        matched.length > 0,
        matched.length > 0 ? `matched: ${matched.join(', ')}` : 'no term matched'
      );
    }

    case 'response_not_contains': {
      const terms = toStringArray(value);
      const leaked = terms.filter((term) => response.includes(term));
      return result(
        assertion,
        leaked.length === 0,
        leaked.length === 0 ? 'no leakage' : `leaked: ${leaked.join(', ')}`
      );
    }

    case 'response_not_empty': {
      const passed = response.trim().length > 0;
      return result(assertion, passed, passed ? `length=${response.length}` : 'empty response');
    }

    default:
      return result(assertion, false, `unknown assertion type: ${type}`);
  }
}

function result(assertion: Assertion, passed: boolean, details: string): AssertionResult {
  return {
    assertion,
    passed,
    details,
    level: 'must',
  };
}

function toStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value.map((item) => String(item));
}

async function executeFlow(flow: Flow): Promise<FlowResult> {
  let sessionId = flow.session === 'new' ? await createSession() : flow.session;
  const assertions: AssertionResult[] = [];

  for (const turn of flow.turns) {
    const chat = await sendMessage(turn.send, sessionId);
    sessionId = chat.sessionId;
    const toolCalls = chat.metadata.toolCalls ?? [];

    for (const must of turn.assert?.must ?? []) {
      const r = evaluateAssertion(must, chat.response, toolCalls);
      r.level = 'must';
      assertions.push(r);
    }

    for (const should of turn.assert?.should ?? []) {
      const r = evaluateAssertion(should, chat.response, toolCalls);
      r.level = 'should';
      assertions.push(r);
    }
  }

  return { name: flow.name, sessionId, assertions };
}

async function runFlowFile(filePath: string): Promise<RunResult> {
  const raw = fs.readFileSync(filePath, 'utf8');
  const testFile = parseYaml(raw) as TestFile;

  const flows: FlowResult[] = [];
  for (const flow of testFile.flows) {
    console.log(`Flow: ${flow.name}`);
    flows.push(await executeFlow(flow));
  }

  let mustTotal = 0;
  let mustPassed = 0;
  let shouldTotal = 0;
  let shouldPassed = 0;

  for (const flow of flows) {
    for (const item of flow.assertions) {
      if (item.level === 'must') {
        mustTotal += 1;
        if (item.passed) mustPassed += 1;
      } else {
        shouldTotal += 1;
        if (item.passed) shouldPassed += 1;
      }
    }
  }

  const shouldRate = shouldTotal === 0 ? 1 : shouldPassed / shouldTotal;
  const overallPass = mustPassed === mustTotal && shouldRate >= 0.8;

  return {
    name: testFile.name,
    timestamp: new Date().toISOString(),
    flows,
    summary: {
      mustTotal,
      mustPassed,
      shouldTotal,
      shouldPassed,
      overallPass,
    },
  };
}

function writeResult(sourceFile: string, data: RunResult): string {
  fs.mkdirSync(RESULTS_DIR, { recursive: true });
  const base = path.basename(sourceFile, path.extname(sourceFile));
  const date = new Date().toISOString().slice(0, 10);
  const filePath = path.join(RESULTS_DIR, `${base}-results-${date}.json`);
  fs.writeFileSync(filePath, JSON.stringify(data, null, 2), 'utf8');
  return filePath;
}

async function main() {
  const args = process.argv.slice(2);
  const flowIndex = args.indexOf('--flow');
  const runAll = args.includes('--all');

  const flowFiles: string[] = [];

  if (flowIndex >= 0 && args[flowIndex + 1]) {
    flowFiles.push(path.resolve(args[flowIndex + 1]));
  } else if (runAll) {
    const dir = path.resolve('test-flows');
    const files = fs.readdirSync(dir).filter((file) => file.endsWith('.yaml'));
    for (const file of files) {
      flowFiles.push(path.join(dir, file));
    }
  } else {
    console.error('Usage:');
    console.error('  npx tsx scripts/test-runner.ts --flow test-flows/feature-smoke.yaml');
    console.error('  npx tsx scripts/test-runner.ts --all');
    process.exit(1);
  }

  let allPass = true;

  for (const file of flowFiles) {
    console.log(`\n== Running ${path.basename(file)} ==`);
    const result = await runFlowFile(file);
    const output = writeResult(file, result);

    console.log(`MUST  : ${result.summary.mustPassed}/${result.summary.mustTotal}`);
    console.log(`SHOULD: ${result.summary.shouldPassed}/${result.summary.shouldTotal}`);
    console.log(`RESULT: ${result.summary.overallPass ? 'PASS' : 'FAIL'}`);
    console.log(`Saved : ${output}`);

    if (!result.summary.overallPass) {
      allPass = false;
    }
  }

  process.exit(allPass ? 0 : 1);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
