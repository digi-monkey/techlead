#!/usr/bin/env node
/**
 * OpenCode 持续迭代控制脚本
 * 用法: node iterate.mjs [迭代次数]
 * 默认迭代 20 次
 */

import { execSync, spawn } from 'child_process';
import { existsSync, mkdirSync, readFileSync, createWriteStream, writeFileSync } from 'fs';
import { join, resolve } from 'path';
import { fileURLToPath } from 'url';

// 获取当前文件目录
const __filename = fileURLToPath(import.meta.url);
const __dirname = resolve(__filename, '..');

// 配置
const CONFIG = {
  iterations: parseInt(process.argv[2], 10) || parseInt(process.env.ITERATIONS, 10) || 20,
  programFile: process.env.PROGRAM_FILE || './program.md',
  opencodeUrl: process.env.OPENCODE_URL || 'http://localhost:4096',
  workDir: process.env.WORK_DIR || '.',
  logDir: process.env.LOG_DIR || './.iteration-logs',
  model: process.env.MODEL || '', // 可选: anthropic/claude-3.5-sonnet 等
  maxBranches: parseInt(process.env.MAX_BRANCHES, 10) || 10,
};

// 颜色输出
const COLORS = {
  red: '\x1b[0;31m',
  green: '\x1b[0;32m',
  yellow: '\x1b[1;33m',
  blue: '\x1b[0;34m',
  nc: '\x1b[0m', // No Color
};

// 日志函数
const log = {
  info: (msg) => console.log(`${COLORS.blue}[INFO]${COLORS.nc} ${msg}`),
  success: (msg) => console.log(`${COLORS.green}[SUCCESS]${COLORS.nc} ${msg}`),
  warn: (msg) => console.log(`${COLORS.yellow}[WARN]${COLORS.nc} ${msg}`),
  error: (msg) => console.log(`${COLORS.red}[ERROR]${COLORS.nc} ${msg}`),
};

/**
 * 执行 shell 命令并返回输出
 * @param {string} cmd - 命令
 * @param {object} options - 选项
 * @returns {string} 命令输出
 */
function exec(cmd, options = {}) {
  const defaultOptions = {
    cwd: CONFIG.workDir,
    encoding: 'utf8',
    stdio: options.stdio || 'pipe',
    ...options,
  };
  return execSync(cmd, defaultOptions).toString().trim();
}

/**
 * 检查命令是否存在
 * @param {string} cmd - 命令
 * @returns {boolean}
 */
function commandExists(cmd) {
  try {
    execSync(`which ${cmd}`, { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}

/**
 * 发起 HTTP 请求检查服务是否可用
 * @param {string} url - 服务 URL
 * @returns {Promise<boolean>}
 */
async function checkHttpService(url) {
  try {
    const response = await fetch(url, { method: 'HEAD' });
    return response.ok;
  } catch {
    return false;
  }
}

/**
 * 初始化
 */
function init() {
  log.info('初始化迭代环境...');
  log.info(`工作目录: ${resolve(CONFIG.workDir)}`);

  // 检查 program.md 存在
  const programPath = resolve(CONFIG.workDir, CONFIG.programFile);
  if (!existsSync(programPath)) {
    log.error(`找不到 ${programPath}`);
    process.exit(1);
  }
  log.info(`Program 文件: ${programPath}`);

  // 创建日志目录
  const logPath = resolve(CONFIG.workDir, CONFIG.logDir);
  mkdirSync(logPath, { recursive: true });

  // 检查当前目录是 git 仓库
  try {
    execSync('git rev-parse --git-dir', {
      cwd: CONFIG.workDir,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    log.info('Git 仓库检查通过');
  } catch (err) {
    log.error('当前目录不是 git 仓库');
    log.error(`尝试运行的目录: ${resolve(CONFIG.workDir)}`);
    process.exit(1);
  }

  log.success('初始化完成');
  console.log();
}

/**
 * 检查 opencode serve 是否可用
 */
async function checkOpencode() {
  log.info('检查 OpenCode server...');

  if (!(await checkHttpService(CONFIG.opencodeUrl))) {
    log.error(`无法连接到 OpenCode server at ${CONFIG.opencodeUrl}`);
    log.info('请确保 OpenCode serve 正在运行:');
    log.info('  opencode serve');
    log.info('或者指定其他地址:');
    log.info('  OPENCODE_URL=http://localhost:8080 node iterate.mjs');
    process.exit(1);
  }

  log.success('OpenCode server 连接正常');
  console.log();
}

/**
 * 获取当前 experiment 分支（如果有）
 * @returns {string|null}
 */
function getCurrentExperimentBranch() {
  try {
    const currentBranch = exec('git branch --show-current');
    return currentBranch.startsWith('experiment-') ? currentBranch : null;
  } catch {
    return null;
  }
}

/**
 * 准备 prompt
 * @param {number} iteration - 迭代次数
 * @param {string|null} experimentBranch - 当前 experiment 分支
 * @returns {string}
 */
function preparePrompt(iteration, experimentBranch) {
  // 读取 program.md
  const programContent = readFileSync(CONFIG.programFile, 'utf8');

  let prompt = `=== 系统消息 ===
你是一个代码改进助手。这是第 ${iteration} 次迭代。

=== 当前状态 ===
- 当前迭代: ${iteration} / ${CONFIG.iterations}
`;

  if (experimentBranch) {
    prompt += `- 当前分支: ${experimentBranch}（需要评估）\n`;
    prompt += '- 需要评估这个分支的工作是否值得保留\n';
  } else {
    prompt += `- 当前分支: develop（需要开始新的实验）\n`;
    prompt += '- 需要创建新的 experiment-* 分支进行改进\n';
  }

  prompt += `
=== program.md 内容 ===
${programContent}

=== 任务指令 ===
`;

  if (experimentBranch) {
    prompt += `
当前有一个 experiment 分支需要评估。

请执行以下操作：
1. 查看当前分支的改动: git diff develop..HEAD
2. 根据 program.md 中的评估标准判断这个改动是否有帮助
3. 做出决策并执行：
   - 如果有帮助：执行 \`git checkout develop && git merge <分支名>\`，然后输出 "DECISION: KEEP"
   - 如果没帮助：执行 \`git branch -D <分支名>\`，然后输出 "DECISION: DISCARD"
4. 简要说明你的判断理由

请直接执行 git 命令，不要只输出命令。
`;
  } else {
    prompt += `
当前在 develop 分支，需要开始新的实验。

请执行以下操作：
1. 根据 program.md 中的 Goal 和已有工作，提出一个改进想法
2. 创建一个描述性的分支名（如 experiment-optimize-memory）
3. 执行: \`git checkout -b experiment-{你的描述}\`
4. 实现你的改进想法（编辑代码、添加功能、优化性能等）
5. 执行: \`git add . && git commit -m "迭代X: 你的描述"\`
6. 输出 "DECISION: EXPERIMENT_CREATED" 和简要的改进说明

注意：不要 merge 到 develop，只 commit 到当前分支。
`;
  }

  return prompt;
}

/**
 * 执行 opencode 命令并实时输出
 * @param {string[]} args - 命令参数
 * @param {string} logFile - 日志文件路径
 * @returns {Promise<boolean>}
 */
function runOpencode(args, logFile) {
  return new Promise((resolve) => {
    const cmd = spawn('opencode', args, {
      cwd: CONFIG.workDir,
      stdio: ['inherit', 'pipe', 'pipe'],
    });

    const logStream = createWriteStream(logFile, { flags: 'a' });

    let output = '';

    cmd.stdout.on('data', (data) => {
      const str = data.toString();
      output += str;
      process.stdout.write(str);
      logStream.write(str);
    });

    cmd.stderr.on('data', (data) => {
      const str = data.toString();
      output += str;
      process.stderr.write(str);
      logStream.write(str);
    });

    cmd.on('close', (code) => {
      logStream.end();
      resolve(code === 0);
    });

    cmd.on('error', (err) => {
      log.error(`执行 opencode 失败: ${err.message}`);
      logStream.end();
      resolve(false);
    });
  });
}

/**
 * 调用 OpenCode
 * @param {number} iteration - 迭代次数
 * @param {string} prompt - prompt 内容
 * @returns {Promise<boolean>}
 */
async function invokeOpencode(iteration, prompt) {
  const logFile = join(CONFIG.logDir, `iteration-${iteration}.log`);
  const currentBranch = exec('git branch --show-current');

  log.info(`第 ${iteration} 次迭代：调用 OpenCode...`);
  log.info(`当前分支: ${currentBranch}`);

  // 构建 opencode run 命令参数
  const args = ['run', '--attach', CONFIG.opencodeUrl];

  // 如果指定了模型，添加 --model
  if (CONFIG.model) {
    args.push('--model', CONFIG.model);
  }

  // 添加 prompt
  args.push(prompt);

  log.info(`执行: opencode ${args.join(' ')}`);

  // 清空日志文件
  writeFileSync(logFile, '');

  const success = await runOpencode(args, logFile);

  if (!success) {
    log.error('调用 OpenCode 失败');
    log.info(`日志保存在: ${logFile}`);
    return false;
  }

  // 解析决策
  const logContent = readFileSync(logFile, 'utf8');
  const decisionMatch = logContent.match(/DECISION: (KEEP|DISCARD|EXPERIMENT_CREATED)/);
  const decision = decisionMatch ? decisionMatch[0] : null;

  if (decision) {
    switch (decision) {
      case 'DECISION: KEEP':
        log.success('决策: 保留分支');
        break;
      case 'DECISION: DISCARD':
        log.warn('决策: 舍弃分支');
        break;
      case 'DECISION: EXPERIMENT_CREATED':
        log.success('决策: 创建了新实验分支');
        break;
    }
  } else {
    log.warn(`无法解析决策，请查看日志: ${logFile}`);
  }

  return true;
}

/**
 * 清理旧的 experiment 分支
 */
function cleanupOldBranches() {
  try {
    const branchesOutput = exec('git branch --list experiment-*');
    const branches = branchesOutput.split('\n').filter(b => b.trim());

    if (branches.length > CONFIG.maxBranches) {
      log.warn(`experiment 分支数量 (${branches.length}) 超过限制 (${CONFIG.maxBranches})`);
      log.info('清理旧分支...');

      // 删除最旧的分支（按字母排序，通常也是创建顺序）
      const branchesToDelete = branches.slice(0, branches.length - CONFIG.maxBranches);
      for (const branch of branchesToDelete) {
        const branchName = branch.trim().replace(/^\*\s*/, '');
        try {
          exec(`git branch -D ${branchName}`);
          log.info(`已删除分支: ${branchName}`);
        } catch (err) {
          log.warn(`无法删除分支 ${branchName}: ${err.message}`);
        }
      }
    }
  } catch {
    // 没有 experiment 分支，忽略错误
  }
}

/**
 * 睡眠函数
 * @param {number} ms - 毫秒
 * @returns {Promise<void>}
 */
function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

/**
 * 显示帮助信息
 */
function showHelp() {
  console.log(`
OpenCode 持续迭代控制脚本

用法:
    node iterate.mjs [迭代次数]

环境变量:
    ITERATIONS      默认迭代次数 (默认: 20)
    PROGRAM_FILE    program.md 文件路径 (默认: ./program.md)
    OPENCODE_URL    OpenCode server URL (默认: http://localhost:4096)
    WORK_DIR        工作目录 (默认: 当前目录)
    LOG_DIR         日志目录 (默认: ./.iteration-logs)
    MODEL           模型选择 (可选, 如: anthropic/claude-3.5-sonnet)
    MAX_BRANCHES    最大保留分支数 (默认: 10)

示例:
    # 默认 20 次迭代
    node iterate.mjs

    # 指定 50 次迭代
    node iterate.mjs 50

    # 使用自定义配置
    OPENCODE_URL=http://localhost:8080 MODEL=anthropic/claude-3.5-sonnet node iterate.mjs 30

要求:
    1. 当前目录是 git 仓库
    2. OpenCode serve 在指定 URL 运行
       启动命令: opencode serve
    3. opencode CLI 已安装

工作流程:
    1. 脚本检查当前是否有 experiment-* 分支
    2. 如果有：让 AI 评估是否保留（合并或删除）
    3. 如果没有：让 AI 创建新分支并实施改进
    4. 循环直到达到指定迭代次数

日志:
    每次迭代的详细输出保存在 LOG_DIR/iteration-N.log
`);
}

/**
 * 主循环
 */
async function main() {
  console.log('========================================');
  console.log('  OpenCode 持续迭代系统');
  console.log('========================================');
  console.log();
  log.info('配置:');
  log.info(`  - 迭代次数: ${CONFIG.iterations}`);
  log.info(`  - Program 文件: ${CONFIG.programFile}`);
  log.info(`  - OpenCode URL: ${CONFIG.opencodeUrl}`);
  log.info(`  - 日志目录: ${CONFIG.logDir}`);
  if (CONFIG.model) {
    log.info(`  - 模型: ${CONFIG.model}`);
  }
  console.log();

  // 检查 opencode CLI
  if (!commandExists('opencode')) {
    log.error('找不到 opencode CLI，请确保已安装');
    process.exit(1);
  }

  // 初始化
  init();
  await checkOpencode();

  // 迭代循环
  for (let i = 1; i <= CONFIG.iterations; i++) {
    console.log('========================================');
    log.info(`第 ${i} / ${CONFIG.iterations} 次迭代`);
    console.log('========================================');
    console.log();

    // 获取当前 experiment 分支
    const experimentBranch = getCurrentExperimentBranch();

    // 准备 prompt
    const prompt = preparePrompt(i, experimentBranch);

    // 调用 OpenCode
    const success = await invokeOpencode(i, prompt);
    if (!success) {
      log.error(`第 ${i} 次迭代失败，跳过...`);
      continue;
    }

    // 清理旧分支
    cleanupOldBranches();

    // 显示当前状态
    console.log();
    log.info('当前 git 状态:');
    try {
      const branchOutput = exec('git branch -v');
      const relevantBranches = branchOutput
        .split('\n')
        .filter(line => line.includes('develop') || line.includes('experiment-'));
      relevantBranches.forEach(line => console.log(line));
    } catch {
      // 忽略错误
    }
    console.log();

    // 短暂休息，避免请求过快
    if (i < CONFIG.iterations) {
      log.info('等待 2 秒后开始下一次迭代...');
      await sleep(2000);
    }

    console.log();
  }

  console.log('========================================');
  log.success('迭代完成！');
  console.log('========================================');
  console.log();
  log.info('总结:');
  log.info(`  - 总迭代次数: ${CONFIG.iterations}`);
  log.info(`  - 日志目录: ${CONFIG.logDir}`);
  log.info(`  - 当前分支: ${exec('git branch --show-current')}`);
  console.log();
  log.info('保留的 experiment 分支:');
  try {
    const experimentBranches = exec('git branch -v | grep experiment- || true');
    if (experimentBranches) {
      console.log(experimentBranches);
    } else {
      log.info('  无');
    }
  } catch {
    log.info('  无');
  }
  console.log();
  log.info('你可以手动评估这些分支，决定最终保留哪些改进。');
}

// 处理参数
const args = process.argv.slice(2);
if (args.includes('-h') || args.includes('--help')) {
  showHelp();
  process.exit(0);
}

// 运行主程序
main().catch((err) => {
  log.error(`发生错误: ${err.message}`);
  console.error(err);
  process.exit(1);
});
