/// <reference types="vitest" />
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    globals: false,
    environment: 'node',
    coverage: {
      // cobertura is uploaded to GitHub Code Quality (coverage/cobertura-coverage.xml)
      reporter: ['text', 'json', 'json-summary', 'html', 'cobertura'],
    },
  },
});
