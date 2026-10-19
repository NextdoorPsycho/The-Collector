import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { CardHintConfiguration, CardHintDependencies, CardHints, MAX_CARD_IMAGE_BYTES, cardHintsStatus, parseCardHints, suggestCardHints, validateCardHintImage } from '../src/card_hints';

const caller = { uid: 'alice', appVerified: true };
const configuration: CardHintConfiguration = { project: 'collector-test', location: 'us-central1', model: 'configured-model' };
const hints: CardHints = {
  name: 'Circle of Protection: Blue', setCode: null, collectorNumber: null,
  rulesText: '{1}: The next time a blue source of your choice would deal damage to you this turn, prevent that damage.',
  typeLine: 'Enchantment', artist: null, language: null,
};

function jpeg(width = 1000, height = 1400): string {
  const bytes = Buffer.from([
    0xff, 0xd8,
    0xff, 0xc0, 0, 17, 8, 0, 0, 0, 0, 3, 1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0,
    0xff, 0xda, 0, 12, 3, 1, 0, 2, 0, 3, 0, 0, 63, 0,
    1, 2, 3, 4, 0xff, 0xd9,
  ]);
  bytes.writeUInt16BE(height, 7);
  bytes.writeUInt16BE(width, 9);
  return bytes.toString('base64');
}
const payload = { imageBase64: jpeg() };

test('status reports configured literal transcription without accepting images or invoking a model', () => {
  assert.deepEqual(cardHintsStatus(caller, {}, configuration), {
    configured: true, mode: 'text-transcription', model: 'configured-model',
  });
  for (const invalid of [{ ...configuration, model: '' }, { ...configuration, project: 'bad/project' },
    { ...configuration, location: 'other.invalid' }, { ...configuration, model: '../model' }]) {
    assert.deepEqual(cardHintsStatus(caller, {}, invalid), { configured: false, mode: 'text-transcription', model: null });
  }
  for (const request of [payload, null, [], 'status', { uid: 'bob' }]) {
    assert.throws(() => cardHintsStatus(caller, request, configuration), { code: 'invalid-argument' });
  }
  assert.throws(() => cardHintsStatus(undefined, {}, configuration), { code: 'unauthenticated', reason: 'sign-in-required' });
  assert.throws(() => cardHintsStatus({ uid: 'alice', appVerified: false }, {}, configuration), { code: 'failed-precondition', reason: 'app-verification-required' });
});

function modelResponse(observations: unknown = hints, finishReason = 'STOP'): Response {
  return Response.json({ candidates: [{ finishReason, content: { parts: [{ text: JSON.stringify(observations) }] } }] });
}
function dependencies(response: () => Response = modelResponse): CardHintDependencies {
  return { accessToken: async () => 'test-token', fetch: async () => response() };
}

test('authentication and App Check precede all paid model work', async () => {
  let requests = 0;
  const injected: CardHintDependencies = {
    accessToken: async () => { requests++; return 'token'; },
    fetch: async () => { requests++; return modelResponse(); },
  };
  for (const invalid of [undefined, { uid: '', appVerified: true }, { uid: 'other/path', appVerified: true }]) {
    await assert.rejects(suggestCardHints(invalid, payload, configuration, injected), { code: 'unauthenticated' });
  }
  await assert.rejects(suggestCardHints({ uid: 'alice', appVerified: false }, payload, configuration, injected), { code: 'failed-precondition' });
  assert.equal(requests, 0);
});

test('request contract accepts only bounded image bytes, never URLs or model selectors', async () => {
  let requests = 0;
  const injected: CardHintDependencies = { accessToken: async () => { requests++; return 'token'; }, fetch: async () => modelResponse() };
  for (const invalid of [null, [], {}, 'https://example.com', { imageBase64: jpeg(), uid: 'bob' },
    { imageBase64: jpeg(), model: 'expensive' }, { imageBase64: 'https://example.com' },
    { imageBase64: 'data:image/jpeg;base64,' + jpeg() }, { imageBase64: jpeg() + '\n' },
    { imageBase64: Buffer.alloc(MAX_CARD_IMAGE_BYTES + 1).toString('base64') },
    { imageBase64: jpeg(63) }, { imageBase64: jpeg(4097) },
    { imageBase64: Buffer.from([0xff, 0xd8, 0xff, 0xd9]).toString('base64') }]) {
    await assert.rejects(suggestCardHints(caller, invalid, configuration, injected), { code: 'invalid-argument' });
  }
  assert.equal(requests, 0);
  assert.equal(validateCardHintImage(payload).mimeType, 'image/jpeg');
});

test('PNG crops use inferred MIME and dimensions; truncated PNG is rejected', () => {
  const png: Buffer = readFileSync('../the_collector/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@1x.png');
  assert.equal(validateCardHintImage({ imageBase64: png.toString('base64') }).mimeType, 'image/png');
  assert.throws(() => validateCardHintImage({ imageBase64: png.subarray(0, png.length - 12).toString('base64') }), { code: 'invalid-argument' });
  const tooLarge: Buffer = Buffer.from(png);
  tooLarge.writeUInt32BE(5000, 16);
  assert.throws(() => validateCardHintImage({ imageBase64: tooLarge.toString('base64') }), { code: 'invalid-argument' });
});

test('missing configuration and URL injection fail before credentials or inference', async () => {
  let credentials = 0;
  for (const invalid of [
    { ...configuration, model: '' }, { ...configuration, model: '../other/model' },
    { ...configuration, location: 'us-central1.evil.test' }, { ...configuration, project: 'other/project' },
  ]) {
    await assert.rejects(suggestCardHints(caller, payload, invalid, {
      accessToken: async () => { credentials++; return 'token'; }, fetch: async () => modelResponse(),
    }), { code: 'failed-precondition' });
  }
  assert.equal(credentials, 0);
});

test('Vertex request uses ADC, fixed endpoint and structured literal observations', async () => {
  let clock = 100;
  const result = await suggestCardHints(caller, payload, configuration, {
    accessToken: async () => 'adc-token', now: () => clock,
    fetch: async (url: string, init: RequestInit) => {
      assert.equal(url, 'https://us-central1-aiplatform.googleapis.com/v1/projects/collector-test/locations/us-central1/publishers/google/models/configured-model:generateContent');
      assert.equal(init.method, 'POST');
      assert.equal((init.headers as Record<string, string>).authorization, 'Bearer adc-token');
      const body = JSON.parse(init.body as string) as {
        contents: { parts: { inlineData?: { mimeType: string; data: string } }[] }[];
        generationConfig: { responseMimeType: string; responseSchema: { required: string[] } };
      };
      assert.deepEqual(body.contents[0]?.parts[0]?.inlineData, { mimeType: 'image/jpeg', data: jpeg() });
      assert.equal(body.generationConfig.responseMimeType, 'application/json');
      assert.equal(body.generationConfig.responseSchema.required.length, 7);
      clock = 147;
      return modelResponse();
    },
  });
  assert.deepEqual(result, { model: 'configured-model', elapsedMs: 47, confidence: 'uncalibrated', hints });
  assert.equal('printingId' in result, false);
  assert.equal('confirmed' in result, false);
});

test('unknown fields and model confidence are never accepted as evidence', () => {
  for (const invalid of [null, [], { ...hints, confidence: .99 }, { ...hints, printingId: 'uuid' },
    { ...hints, name: 3 }, { ...hints, rulesText: 'a'.repeat(1201) },
    { ...hints, setCode: 'https://other' }, { ...hints, language: 'english' },
    { ...hints, collectorNumber: '1/1' }, { ...hints, artist: '\u0000hidden' }]) {
    assert.throws(() => parseCardHints(invalid), { code: 'unavailable' });
  }
  assert.deepEqual(parseCardHints({ ...hints, setCode: ' ICE ', language: 'EN', name: ' ' }), {
    ...hints, setCode: 'ice', language: 'en', name: null,
  });
});

test('incomplete, refused, malformed and oversized model replies are rejected', async () => {
  for (const response of [
    () => Response.json({}),
    () => Response.json({ candidates: [] }),
    () => modelResponse(hints, 'MAX_TOKENS'),
    () => modelResponse({ ...hints, confidence: .98 }),
    () => Response.json({ candidates: [{ finishReason: 'STOP', content: { parts: [{ text: '{invalid' }] } }] }),
    () => Response.json({ candidates: [{ finishReason: 'STOP', content: { parts: [{ text: JSON.stringify(hints) }, { text: 'extra' }] } }] }),
    () => new Response('unavailable', { status: 503 }),
    () => new Response('x'.repeat(65537)),
    () => new Response('{}', { headers: { 'content-length': '100000' } }),
  ]) {
    await assert.rejects(suggestCardHints(caller, payload, configuration, dependencies(response)), { code: 'unavailable' });
  }
});

test('timeout aborts inference and late ADC cannot start a paid request', async () => {
  let resolveToken: ((value: string) => void) | undefined;
  let requests = 0;
  const token = new Promise<string>((resolve) => { resolveToken = resolve; });
  await assert.rejects(suggestCardHints(caller, payload, configuration, {
    timeoutMs: 5, accessToken: () => token,
    fetch: async () => { requests++; return modelResponse(); },
  }), { code: 'deadline-exceeded' });
  resolveToken!('late-token');
  await new Promise<void>((resolve) => setImmediate(resolve));
  assert.equal(requests, 0);
  let signal: AbortSignal | undefined;
  await assert.rejects(suggestCardHints(caller, payload, configuration, {
    timeoutMs: 5, accessToken: async () => 'token',
    fetch: async (_url: string, init: RequestInit) => {
      signal = init.signal ?? undefined;
      return new Promise<Response>(() => undefined);
    },
  }), { code: 'deadline-exceeded' });
  assert.equal(signal?.aborted, true);
});

test('global endpoint remains fixed and all unreadable fields can be null', async () => {
  const empty: CardHints = { name: null, setCode: null, collectorNumber: null, rulesText: null, typeLine: null, artist: null, language: null };
  const result = await suggestCardHints(caller, payload, { ...configuration, location: 'global' }, {
    accessToken: async () => 'token',
    fetch: async (url: string) => {
      assert.equal(new URL(url).hostname, 'aiplatform.googleapis.com');
      return modelResponse(empty);
    },
  });
  assert.deepEqual(result.hints, empty);
});
