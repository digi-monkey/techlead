/**
 * Config loader for TechLead
 * Supports loading config from multiple sources with priority
 */

import { existsSync, readFileSync } from "node:fs";
import { resolve, join } from "node:path";
import { pathToFileURL } from "node:url";
import { homedir } from "node:os";

export interface TechLeadConfig {
  /**
   * Default agent provider
   * @default "claude"
   */
  provider?: "claude" | "codex";

  /**
   * Default model to use
   */
  model?: string;

  /**
   * Maximum budget in USD per execution
   * @default 1.0
   */
  maxBudgetUsd?: number;

  /**
   * Allowed tools for agent
   */
  allowedTools?: string[];

  /**
   * Working directory for agent
   */
  workingDir?: string;

  /**
   * Enable execution logging
   * @default false
   */
  enableLogging?: boolean;

  /**
   * Default log directory
   */
  logDir?: string;

  /**
   * Default timeout in milliseconds
   * @default 300000 (5 minutes)
   */
  timeoutMs?: number;

  /**
   * Custom environment variables for agent
   */
  env?: Record<string, string>;
}

// Default configuration
const defaultConfig: TechLeadConfig = {
  provider: "claude",
  maxBudgetUsd: 1.0,
  allowedTools: ["Read", "Edit", "Bash", "Glob"],
  enableLogging: false,
  timeoutMs: 300000,
};

/**
 * Possible config file names
 */
const CONFIG_FILES = [
  "techlead.config.js",
  "techlead.config.mjs",
  ".techleadrc.json",
  ".techleadrc",
];

/**
 * Load config from a specific file path
 */
async function loadConfigFile(configPath: string): Promise<Partial<TechLeadConfig> | null> {
  if (!existsSync(configPath)) {
    return null;
  }

  try {
    // JSON config
    if (configPath.endsWith(".json") || configPath.endsWith(".techleadrc")) {
      const content = readFileSync(configPath, "utf8");
      return JSON.parse(content) as Partial<TechLeadConfig>;
    }

    // JS/ESM config
    if (configPath.endsWith(".js") || configPath.endsWith(".mjs")) {
      // Clear module cache for hot reload in development
      const modulePath = pathToFileURL(resolve(configPath)).href;
      const config = await import(modulePath);
      return config.default || config;
    }

    return null;
  } catch (error) {
    console.error(`Failed to load config from ${configPath}:`, error);
    return null;
  }
}

/**
 * Find config file in given directory
 */
function findConfigFile(dir: string): string | null {
  for (const fileName of CONFIG_FILES) {
    const configPath = join(dir, fileName);
    if (existsSync(configPath)) {
      return configPath;
    }
  }
  return null;
}

/**
 * Load configuration from all sources
 * Priority: CLI args > Project config > Home config > Defaults
 */
export async function loadConfig(
  cliArgs: Partial<TechLeadConfig> = {},
  cwd: string = process.cwd()
): Promise<TechLeadConfig> {
  const configs: Partial<TechLeadConfig>[] = [defaultConfig];

  // 1. Load from home directory (lowest priority)
  const homeConfigPath = findConfigFile(homedir());
  if (homeConfigPath) {
    const homeConfig = await loadConfigFile(homeConfigPath);
    if (homeConfig) {
      configs.push(homeConfig);
    }
  }

  // 2. Load from project directory
  const projectConfigPath = findConfigFile(cwd);
  if (projectConfigPath) {
    const projectConfig = await loadConfigFile(projectConfigPath);
    if (projectConfig) {
      configs.push(projectConfig);
    }
  }

  // 3. CLI arguments (highest priority)
  configs.push(cliArgs);

  // Merge all configs
  return deepMerge(...configs);
}

/**
 * Deep merge multiple config objects
 */
function deepMerge(...objects: Partial<TechLeadConfig>[]): TechLeadConfig {
  const result: Record<string, unknown> = {};

  for (const obj of objects) {
    for (const [key, value] of Object.entries(obj)) {
      if (value === undefined) continue;

      // Handle nested objects (like env)
      if (
        typeof value === "object" &&
        value !== null &&
        !Array.isArray(value) &&
        typeof result[key] === "object" &&
        result[key] !== null
      ) {
        result[key] = { ...result[key], ...value };
      } else {
        result[key] = value;
      }
    }
  }

  return result as TechLeadConfig;
}

/**
 * Get the path of the loaded config file (for debugging)
 */
export function getConfigPath(cwd: string = process.cwd()): string | null {
  // Check project directory first
  const projectConfig = findConfigFile(cwd);
  if (projectConfig) {
    return projectConfig;
  }

  // Then home directory
  const homeConfig = findConfigFile(homedir());
  if (homeConfig) {
    return homeConfig;
  }

  return null;
}
