import assert from 'node:assert/strict';
import {setTimeout as delay} from 'node:timers/promises';
import test from 'node:test';
import {SerialJobQueue, startSchedules, WikiJobs} from '../dist/scheduler.js';

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
    quality: {
      lint: {enabled: true},
      eval: {enabled: true, suite: 'fast'},
    },
    viewer: {
      internalPort: 54321,
      publicHost: '0.0.0.0',
      publicPort: 8080,
      startupTimeoutSeconds: 30,
      reloadPollSeconds: 2,
    },
  };
  const queue = new SerialJobQueue();
  const jobs = {ingest: async () => {}, compile: async () => {}};

  assert.throws(() => startSchedules(config, jobs, queue));
});

test('ingest後にcompile、lint、evalを順番に実行する', async () => {
  const events = [];
  const config = {
    compile: {onIngest: true},
    quality: {
      lint: {enabled: true},
      eval: {enabled: true, suite: 'fast'},
    },
  };
  const client = {
    ingest: async () => events.push('ingest'),
    compile: async () => events.push('compile'),
    lint: async () => events.push('lint'),
    eval: async () => events.push('eval'),
  };
  const jobs = new WikiJobs(config, client);

  await jobs.ingest({id: 'obsidian-couchdb'});

  assert.deepEqual(events, ['ingest', 'compile', 'lint', 'eval']);
});
