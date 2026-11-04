import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    include: ['test/**/*.test.ts'],
    // 集成测试共用一个数据库，串行跑
    fileParallelism: false,
    testTimeout: 20000,
    hookTimeout: 30000,
  },
});
