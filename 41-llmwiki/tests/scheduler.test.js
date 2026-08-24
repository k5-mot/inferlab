import assert from 'node:assert/strict';
import {setTimeout as delay} from 'node:timers/promises';
import test from 'node:test';
import {SerialJobQueue, startSchedules} from '../dist/scheduler.js';

test('jobを登録順に直列実行する', async () => {
  const queue = new SerialJobQueue();
  const events = [];
  void queue.enqueue('first', async () => {
    events.push('first:start');
    await delay(20);
    events.push('first:end');
  });
  void queue.enqueue('second', async () => {
    events.push('second:start');
    events.push('second:end');
  });

  await queue.idle();

  assert.deepEqual(events, ['first:start', 'first:end', 'second:start', 'second:end']);
});

test('無効化されたscheduleも起動時に検証する', () => {
  const config = {
    projectRoot: '/data/llmwiki',
    timezone: 'Asia/Tokyo',
    sources: [],
    compile: {
      enabled: false,
      schedule: 'not-a-cron',
      onIngest: false,
      concurrency: 5,
      review: false,
      timeoutSeconds: 3600,
    },
    provider: {
      kind: 'openai',
      model: 'model',
      baseUrl: 'http://litellm:4000/v1',
      credentialEnv: 'KEY',
      embedding: {
        kind: 'openai',
        model: 'embedding-model',
        baseUrl: 'http://litellm:4000/v1',
        credentialEnv: 'KEY',
        batchSize: 2,
        strict: false,
      },
    },
    outputLanguage: 'Japanese',
    viewer: {
      internalPort: 54321,
      publicHost: '0.0.0.0',
      publicPort: 8080,
      startupTimeoutSeconds: 30,
    },
  };
  const queue = new SerialJobQueue();
  const jobs = {ingest: async () => {}, compile: async () => {}};

  assert.throws(() => startSchedules(config, jobs, queue));
});
