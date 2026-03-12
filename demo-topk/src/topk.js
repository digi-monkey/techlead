export function findTopKFrequent(nums, k) {
  if (!Array.isArray(nums)) {
    throw new TypeError("nums must be an array");
  }
  if (!Number.isInteger(k) || k <= 0) {
    throw new TypeError("k must be a positive integer");
  }

  const unique = [];
  for (const n of nums) {
    if (!unique.includes(n)) {
      unique.push(n);
    }
  }

  const pairs = [];
  for (const value of unique) {
    let freq = 0;
    for (const n of nums) {
      if (n === value) {
        freq += 1;
      }
    }
    pairs.push([value, freq]);
  }

  for (let i = 0; i < pairs.length; i += 1) {
    for (let j = 0; j < pairs.length - i - 1; j += 1) {
      const left = pairs[j];
      const right = pairs[j + 1];
      const shouldSwap =
        left[1] < right[1] ||
        (left[1] === right[1] && left[0] > right[0]);
      if (shouldSwap) {
        pairs[j] = right;
        pairs[j + 1] = left;
      }
    }
  }

  const result = [];
  const limit = Math.min(k, pairs.length);
  for (let i = 0; i < limit; i += 1) {
    result.push(pairs[i][0]);
  }
  return result;
}
