import { performance } from "node:perf_hooks";
import { findTopKFrequent } from "./src/topk.js";

function randomInt(max) {
  return Math.floor(Math.random() * max);
}

function buildDataset(size, cardinality) {
  const out = new Array(size);
  for (let i = 0; i < size; i += 1) {
    out[i] = randomInt(cardinality);
  }
  return out;
}

const rounds = 20;
const size = 80_000;
const cardinality = 5_000;
const k = 10;

const input = buildDataset(size, cardinality);
const times = [];

for (let i = 0; i < rounds; i += 1) {
  const start = performance.now();
  findTopKFrequent(input, k);
  const end = performance.now();
  times.push(end - start);
}

const avg = times.reduce((a, b) => a + b, 0) / times.length;
const max = Math.max(...times);
const min = Math.min(...times);

console.log(JSON.stringify({ rounds, size, cardinality, k, avg_ms: avg, min_ms: min, max_ms: max }, null, 2));
