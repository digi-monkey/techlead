#!/usr/bin/env node

import { cac } from 'cac';
import {
  cmdAbort,
  cmdAdd,
  cmdDone,
  cmdHello,
  cmdInit,
  cmdList,
  cmdLoop,
  cmdNext,
  cmdPlan,
  cmdReview,
  cmdRun,
  cmdStart,
  cmdStatus,
  cmdStep,
  cmdTest,
  cmdWorld,
} from './lib/techlead-commands.js';

function main(): void {
  const cli = cac('techlead');

  cli.command('hello', 'Print a hello message').action(cmdHello);
  cli.command('world', 'Ask Claude to say hello to the world').action(cmdWorld);
  cli.command('init', 'Initialize TechLead').action(cmdInit);
  cli.command('add <title>', 'Add a new task').action(cmdAdd);
  cli.command('list', 'List all tasks').action(cmdList);
  cli.command('status', 'Show current status').action(cmdStatus);
  cli.command('plan [taskId]', 'Run plan phase for backlog task').action(cmdPlan);
  cli.command('start [taskId]', 'Move planned task to exec phase').action(cmdStart);
  cli.command('step [taskId]', 'Execute one step in exec phase').action(cmdStep);
  cli.command('review [taskId]', 'Run adversarial review phase').action(cmdReview);
  cli.command('test [taskId]', 'Run adversarial test phase').action(cmdTest);
  cli.command('done [taskId]', 'Mark tested task as done').action(cmdDone);
  cli.command('next', 'Switch to next task in queue').action(cmdNext);
  cli.command('run', 'Auto-run current/next task by composing phase commands').action(cmdRun);
  cli
    .command('loop', 'Continuously run tasks until stop conditions are reached')
    .option('--max-cycles <n>', 'Maximum number of loop cycles', { default: 20 })
    .option('--max-no-progress <n>', 'Stop after N consecutive no-progress cycles', { default: 3 })
    .action((options) => cmdLoop(options));
  cli.command('abort', 'Abort current task').action(cmdAbort);

  cli.help();
  cli.parse();
}

main();
