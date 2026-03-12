import assert from "node:assert/strict";
import { findTopKFrequent } from "./src/topk.js";

function runTests() {
  assert.deepEqual(findTopKFrequent([1, 1, 1, 2, 2, 3], 2), [1, 2]);
  assert.deepEqual(findTopKFrequent([4, 4, 2, 2, 3, 3], 2), [2, 3]);
  assert.deepEqual(findTopKFrequent([9], 1), [9]);
  assert.deepEqual(findTopKFrequent([], 3), []);

  let threw = false;
  try {
    findTopKFrequent("bad", 1);
  } catch {
    threw = true;
  }
  assert.equal(threw, true);

  console.log("All tests passed.");
}

runTests();
