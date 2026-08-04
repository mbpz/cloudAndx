import assert from 'assert';
import { readFile } from 'fs/promises';

const source = await readFile(new URL('../novnc/cloudandx-motion.js', import.meta.url), 'utf8');
const moduleUrl = `data:text/javascript;base64,${Buffer.from(source).toString('base64')}`;
const { consumeMotion, wheelPixels } = await import(moduleUrl);

assert.deepStrictEqual(consumeMotion(40, 18), { step: 18, remaining: 22 });
assert.deepStrictEqual(consumeMotion(-40, 18), { step: -18, remaining: -22 });
assert.deepStrictEqual(consumeMotion(7, 18), { step: 7, remaining: 0 });
assert.deepStrictEqual(wheelPixels({ deltaX: 2, deltaY: -3, deltaMode: 1 }, 720), { x: 32, y: -48 });
assert.deepStrictEqual(wheelPixels({ deltaX: 0, deltaY: 1, deltaMode: 2 }, 720), { x: 0, y: 720 });

console.log('PASS: touch motion is bounded and normalizes wheel delta modes');
