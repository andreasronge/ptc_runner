# DeepSeek v3.2 PTC Test Analysis

**Date:** 2025-12-11
**Model:** openrouter:deepseek/deepseek-v3.2

## Results Summary

| DSL | Pass Rate | Avg Attempts | Duration |
|-----|-----------|--------------|----------|
| Lisp | 85.7% (12/14) | 1.64 | 1.4m |
| JSON | 71.4% (10/14) | 2.14 | 3.6m |

## Key Findings

### 1. Lisp DSL Outperforms JSON DSL

Lisp passed 2 additional tests (#9, #12) due to having `take` and `distinct` operations.

### 2. JSON DSL Missing Operations

| Missing Op | Use Case | Failed Tests |
|------------|----------|--------------|
| `take`/`slice` | Limit results to first N items | #9 |
| `distinct` | Deduplicate list values | #12 |
| `store` | Persistent cross-query memory | #13, #14 |

### 3. String vs Keyword Confusion (Lisp)

The model inconsistently used keywords (`:senior`) vs strings (`"senior"`):

```lisp
(where :department = :engineering)  ; wrong - returns []
(where :department = "engineering") ; correct
```

This caused tests #11 and #14 to fail despite correct logic.

### 4. Test #7 Anomaly

JSON returned 232 credit card orders, Lisp returned 0. Likely cause: keyword vs string mismatch.

## Recommendations

### JSON DSL Improvements

1. **Add `slice` operation** - for taking first N items
2. **Add `distinct` operation** - for deduplication
3. **Add `store`/`recall` operations** - for persistent memory

### Lisp DSL Improvements

1. **Type coercion in `where`** - auto-convert keywords to strings
2. **Better error feedback** - suggest type check when filter returns empty

### Prompt/Schema Improvements

1. **Show sample data values** - so model knows string vs keyword types
2. **Add type hints** - indicate field value types in schema
