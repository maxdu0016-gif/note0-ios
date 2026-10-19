#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { createSign } = require('node:crypto');

const APP_ID = '6808413505';
const API = 'https://api.appstoreconnect.apple.com/v1/';
const POLL_MS = 30_000;
const TIMEOUT_MS = 40 * 60_000;

/** Read the build number and optional release notes from the CLI. */
function argumentsFrom(argv) {
  let buildNumber;
  let notes;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--help') {
      console.log('Usage: node scripts/testflight-external.cjs [build-number] [--notes "What to test"]');
      process.exit(0);
    }
    if (argv[i] === '--notes' && argv[i + 1] && !argv[i + 1].startsWith('--')) notes = argv[++i];
    else if (argv[i] === '--notes' || argv[i].startsWith('-') || buildNumber) throw new Error('Usage: node scripts/testflight-external.cjs [build-number] [--notes "What to test"]');
    else buildNumber = argv[i];
  }
  const app = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'app.json'), 'utf8')).expo;
  buildNumber ??= app.ios.buildNumber;
  if (!/^[1-9]\d*$/.test(String(buildNumber))) throw new Error('Build number must be a positive integer');
  return { buildNumber: String(buildNumber), version: app.version, notes };
}

/** Authenticate each request with a fresh Apple JWT so a 40-minute poll never expires. */
function appleClient() {
  const { ASC_KEY_ID: keyId, ASC_ISSUER_ID: issuerId, ASC_KEY_PATH: keyPath } = process.env;
  if (!keyId || !issuerId || !keyPath) throw new Error('Set ASC_KEY_ID, ASC_ISSUER_ID, and ASC_KEY_PATH to an App Store Connect API key with App Manager access.');
  let privateKey;
  try { privateKey = fs.readFileSync(keyPath, 'utf8'); }
  catch { throw new Error('Cannot read ASC_KEY_PATH.'); }
  const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');

  /** Make one JSON:API request without logging credentials. */
  async function api(resource, method = 'GET', body) {
    const url = new URL(resource, API);
    if (url.origin !== new URL(API).origin) throw new Error('Unexpected App Store Connect pagination URL');
    const now = Math.floor(Date.now() / 1000);
    const input = `${encode({ alg: 'ES256', kid: keyId, typ: 'JWT' })}.${encode({ iss: issuerId, iat: now, exp: now + 600, aud: 'appstoreconnect-v1' })}`;
    const signer = createSign('SHA256');
    signer.update(input);
    const jwt = `${input}.${signer.sign({ key: privateKey, dsaEncoding: 'ieee-p1363' }).toString('base64url')}`;
    const response = await fetch(url, {
      method,
      headers: { Authorization: `Bearer ${jwt}`, Accept: 'application/json', ...(body ? { 'Content-Type': 'application/json' } : {}) },
      ...(body ? { body: JSON.stringify(body) } : {}),
      signal: AbortSignal.timeout(45_000),
    });
    const result = await response.json().catch(() => ({}));
    if (!response.ok) {
      const errors = result.errors?.map(error => `${error.code}: ${error.title}`).join('; ') || 'request failed';
      throw new Error(`Apple HTTP ${response.status} ${url.pathname}: ${errors}`);
    }
    return result;
  }

  /** Follow Apple's paginated collection links. */
  async function list(resource) {
    const data = [];
    while (resource) {
      const page = await api(resource);
      data.push(...page.data);
      resource = page.links?.next;
    }
    return data;
  }
  return { api, list };
}

/** Wait for the exact app version and build number to finish processing. */
async function waitForBuild({ api, buildNumber, version }) {
  const deadline = Date.now() + TIMEOUT_MS;
  let lastState;
  do {
    const page = await api(`builds?filter[app]=${APP_ID}&filter[version]=${buildNumber}&include=preReleaseVersion&limit=200`);
    const versions = new Map((page.included ?? []).map(item => [item.id, item.attributes.version]));
    const build = page.data.find(item => versions.get(item.relationships?.preReleaseVersion?.data?.id) === version);
    if (page.data.length && !build) throw new Error(`Build ${buildNumber} exists, but not for app version ${version}.`);
    const state = build?.attributes.processingState ?? 'not uploaded';
    if (state !== lastState) console.log(`Build ${version} (${buildNumber}): ${state}`);
    lastState = state;
    if (state === 'VALID') return build;
    if (state === 'FAILED' || state === 'INVALID') throw new Error(`Build ${buildNumber} processing failed: ${state}`);
    if (Date.now() >= deadline) break;
    await new Promise(resolve => setTimeout(resolve, Math.min(POLL_MS, deadline - Date.now())));
  } while (true);
  throw new Error(`Build ${buildNumber} was not VALID within 40 minutes.`);
}

/** Check existing TestFlight text and reviewer contacts before changing the build. */
async function checkTestInformation({ api, list }) {
  const localizations = await list(`apps/${APP_ID}/betaAppLocalizations?limit=200`);
  const detail = (await api(`apps/${APP_ID}/betaAppReviewDetail`)).data?.attributes ?? {};
  const missing = [];
  if (!localizations.some(item => /^(en-|zh-)/.test(item.attributes.locale))) missing.push('Chinese or English beta app localization');
  for (const item of localizations) {
    if (!item.attributes.description?.trim()) missing.push(`${item.attributes.locale} beta description`);
    if (!item.attributes.feedbackEmail?.trim()) missing.push(`${item.attributes.locale} feedback email`);
  }
  if (!detail.notes?.trim()) missing.push('beta review test instructions');
  for (const field of ['contactFirstName', 'contactLastName', 'contactPhone', 'contactEmail']) {
    if (!detail[field]?.trim()) missing.push(`beta review ${field}`);
  }
  if (missing.length) throw new Error(`Missing TestFlight information: ${missing.join(', ')}`);
}

/** Create or update the What to Test localization when notes were supplied. */
async function saveNotes({ api, list }, buildId, notes) {
  if (notes === undefined) return;
  const locale = /\p{Script=Han}/u.test(notes) ? 'zh-Hans' : 'en-US';
  const existing = (await list(`builds/${buildId}/betaBuildLocalizations?limit=200`)).find(item => item.attributes.locale === locale);
  if (existing?.attributes.whatsNew === notes) return;
  if (existing) {
    await api(`betaBuildLocalizations/${existing.id}`, 'PATCH', { data: { type: 'betaBuildLocalizations', id: existing.id, attributes: { whatsNew: notes } } });
  } else {
    await api('betaBuildLocalizations', 'POST', { data: { type: 'betaBuildLocalizations', attributes: { locale, whatsNew: notes }, relationships: { build: { data: { type: 'builds', id: buildId } } } } });
  }
  console.log(`What to Test saved (${locale}).`);
}

/** Apply the external testing steps and print the verified state for each group. */
async function main() {
  const options = argumentsFrom(process.argv.slice(2));
  const apple = appleClient();
  const build = await waitForBuild({ ...apple, ...options });
  await checkTestInformation(apple);
  const groups = (await apple.list(`apps/${APP_ID}/betaGroups?limit=200`)).filter(item => item.attributes.isInternalGroup === false);
  if (!groups.length) throw new Error('No external TestFlight groups exist for this app.');
  if (build.attributes.usesNonExemptEncryption !== false) {
    await apple.api(`builds/${build.id}`, 'PATCH', { data: { type: 'builds', id: build.id, attributes: { usesNonExemptEncryption: false } } });
    console.log('Export compliance set to usesNonExemptEncryption=false.');
  }
  await saveNotes(apple, build.id, options.notes);
  for (const group of groups) {
    const members = await apple.list(`betaGroups/${group.id}/relationships/builds?limit=200`);
    if (!members.some(item => item.id === build.id)) {
      await apple.api(`betaGroups/${group.id}/relationships/builds`, 'POST', { data: [{ type: 'builds', id: build.id }] });
      console.log(`Added build ${options.buildNumber} to ${group.attributes.name}.`);
    }
  }
  let reviews = await apple.list(`betaAppReviewSubmissions?filter[build]=${build.id}&limit=200`);
  if (!reviews.length) {
    const created = await apple.api('betaAppReviewSubmissions', 'POST', { data: { type: 'betaAppReviewSubmissions', relationships: { build: { data: { type: 'builds', id: build.id } } } } });
    reviews = [created.data];
    console.log('Submitted for external beta review.');
  }
  const reviewState = reviews.map(item => item.attributes.betaReviewState).join(', ');
  for (const group of groups) {
    const members = await apple.list(`betaGroups/${group.id}/relationships/builds?limit=200`);
    console.log(`${group.attributes.name} (public link ${group.attributes.publicLinkEnabled ? 'on' : 'off'}): build ${options.buildNumber} ${members.some(item => item.id === build.id) ? reviewState : 'not in group'}`);
  }
}

main().catch(error => { console.error(error.message); process.exitCode = 1; });
