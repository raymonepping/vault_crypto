// pages/Agility.jsx — one Transit key name, several algorithms over time.
// The caller's configuration (the path it calls) is pinned at the top and
// never changes; everything below it does.
import { useCallback, useState } from 'react';
import { PenLine, ShieldCheck, Shuffle, Lock, RotateCw, Unlock, Ban } from 'lucide-react';
import { call } from '../api.js';
import { useAction, useResource } from '../hooks.js';
import { Authority, ErrorNotice, FamilyPill, Loading, Locked, Mono, StatePill } from '../components/ui.jsx';
import { short, when } from '../format.js';

const SIGNING_TARGETS = ['ml-dsa-44', 'ml-dsa-65', 'ml-dsa-87', 'hybrid-ml-dsa-65-ecdsa-p256', 'slh-dsa-sha2-128s', 'ecdsa-p256', 'ecdsa-p384', 'ed25519'];
const ENCRYPTION_TARGETS = ['aes256-gcm96', 'chacha20-poly1305', 'aes128-gcm96'];

function nextSigning(latest) {
  if (latest === 'ecdsa-p256') return 'ml-dsa-65';
  if (latest === 'ml-dsa') return 'hybrid-ml-dsa-65-ecdsa-p256';
  return 'ml-dsa-87';
}
const nextEncryption = (latest) => (latest === 'aes128-gcm96' ? 'aes256-gcm96' : latest === 'aes256-gcm96' ? 'chacha20-poly1305' : 'aes256-gcm96');

function Versions({ k }) {
  return (
    <ol className="versions" aria-label={`${k.name} versions`}>
      {k.versions.map((v) => (
        <li key={v.version} className={`versions__item${v.version === k.vault.latest_version ? ' versions__item--latest' : ''}`}>
          <span className="versions__v">v{v.version}</span>
          <FamilyPill family={v.family}>{v.requested || v.type || 'not reported'}</FamilyPill>
          <span className="dim versions__src">{v.typeSource}</span>
          <span className="dim">{when(v.created)}</span>
        </li>
      ))}
    </ol>
  );
}

function Rotate({ keyName, targets, suggested, onDone, crossUsage, action }) {
  const [target, setTarget] = useState(suggested);
  const a = useAction(useCallback((t) => call(`rotate ${keyName} → ${t}`, '/api/agility/rotate', { method: 'POST', body: { key: keyName, target: t } }), [keyName]));
  const go = async (t) => {
    const r = await a.run(t);
    if (r) onDone();
  };
  const id = `target-${keyName}`;
  return (
    <div className="rotate">
      <div className="rotate__row">
        <button type="button" className="primary-button" onClick={() => go(suggested)} disabled={a.busy}>
          <Shuffle size={14} aria-hidden="true" /> Rotate to {suggested}
          <Locked action={action} />
        </button>
        <label className="sr-only" htmlFor={id}>
          Other algorithm for {keyName}
        </label>
        <select id={id} className="vg-filter-select" value={target} onChange={(e) => setTarget(e.target.value)}>
          {targets.map((t) => (
            <option key={t} value={t}>
              {t}
            </option>
          ))}
        </select>
        <button type="button" className="secondary-button" onClick={() => go(target)} disabled={a.busy}>
          Rotate to selected
          <Locked action={action} />
        </button>
        <button type="button" className="secondary-button" onClick={() => go(crossUsage)} disabled={a.busy} data-testid={`cross-${keyName}`}>
          <Ban size={14} aria-hidden="true" /> Try {crossUsage}
        </button>
      </div>
      <ErrorNotice error={a.error} title="Vault refused the rotation" />
      {a.result && !a.error && (
        <p className="inline-notice" role="status">
          Now v{a.result.vault.latest_version}, <Mono>latest_version_type</Mono> = {a.result.vault.latest_version_type}. The key’s{' '}
          <Mono>type</Mono> still reads {a.result.vault.type}: Vault keeps the original.
        </p>
      )}
    </div>
  );
}

function Signing({ data, reload }) {
  const k = data.keys['orders-signing'];
  const [message, setMessage] = useState('order 4711: 3 espresso, table 12');
  const sign = useAction(useCallback((m) => call('sign', '/api/agility/sign', { method: 'POST', body: { message: m } }), []));
  const verify = useAction(useCallback(() => call('verify all', '/api/agility/verify', { method: 'POST' }), []));
  const results = Object.fromEntries((verify.result?.results || []).map((r) => [r.id, r]));
  const doSign = async (e) => {
    e.preventDefault();
    if (await sign.run(message)) {
      verify.clear();
      reload();
    }
  };
  return (
    <section className="vg-card" aria-labelledby="sig-title">
      <div className="chain__head">
        <h3 id="sig-title">
          <Mono>orders-signing</Mono> signs orders
        </h3>
        <FamilyPill family={k.versions.at(-1)?.family}>{k.vault.latest_version_type}</FamilyPill>
      </div>
      <Versions k={k} />
      <Rotate keyName="orders-signing" targets={SIGNING_TARGETS} suggested={nextSigning(k.vault.latest_version_type)} onDone={reload} crossUsage="aes256-gcm96" action="agility.rotate" />

      <form className="sign-form" onSubmit={doSign}>
        <div className="form-field">
          <label htmlFor="sign-message">Message to sign</label>
          <input id="sign-message" value={message} onChange={(e) => setMessage(e.target.value)} maxLength={200} />
        </div>
        <div className="rotate__row">
          <button type="submit" className="primary-button" disabled={sign.busy || !message.trim()}>
            <PenLine size={14} aria-hidden="true" /> {sign.busy ? 'Signing…' : 'Sign'}
            <Locked action="agility.sign" />
          </button>
          <button type="button" className="secondary-button" onClick={() => verify.run()} disabled={verify.busy || !data.signatures.length}>
            <ShieldCheck size={14} aria-hidden="true" /> {verify.busy ? 'Verifying…' : 'Verify every signature now'}
            <Locked action="agility.verify" />
          </button>
        </div>
      </form>
      <ErrorNotice error={sign.error || verify.error} />

      {data.signatures.length > 0 && (
        <div className="table-scroll" tabIndex={0}>
          <table className="vg-table" aria-label="Signatures">
            <thead>
              <tr>
                <th scope="col">#</th>
                <th scope="col">Message</th>
                <th scope="col">Signed by</th>
                <th scope="col">Size</th>
                <th scope="col">Verifies now</th>
              </tr>
            </thead>
            <tbody>
              {data.signatures.map((s) => (
                <tr key={s.id}>
                  <td className="num">{s.id}</td>
                  <td>{s.message}</td>
                  <td>
                    <Mono>v{s.version}</Mono> <FamilyPill family={s.family}>{s.type || 'unknown'}</FamilyPill>
                  </td>
                  <td className="num">{s.chars.toLocaleString('en-GB')} chars</td>
                  <td>
                    {results[s.id] ? (
                      results[s.id].valid ? (
                        <StatePill state="ok">valid under v{verify.result.latestVersion}</StatePill>
                      ) : (
                        <StatePill state="denied">invalid</StatePill>
                      )
                    ) : (
                      <span className="dim">not checked</span>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}

function Ledger({ data, reload }) {
  const k = data.keys['ledger-data'];
  const [label, setLabel] = useState('synthetic ledger line 0001, 1200.00 EUR');
  const enc = useAction(useCallback((l) => call('encrypt', '/api/agility/ledger/encrypt', { method: 'POST', body: { label: l } }), []));
  const rewrap = useAction(useCallback(() => call('rewrap all', '/api/agility/ledger/rewrap', { method: 'POST' }), []));
  const dec = useAction(useCallback(() => call('decrypt all', '/api/agility/ledger/decrypt', { method: 'POST' }), []));
  const plain = Object.fromEntries((dec.result?.entries || []).map((e) => [e.id, e]));
  const doEnc = async (e) => {
    e.preventDefault();
    if (await enc.run(label)) {
      dec.clear();
      reload();
    }
  };
  return (
    <section className="vg-card" aria-labelledby="led-title">
      <div className="chain__head">
        <h3 id="led-title">
          <Mono>ledger-data</Mono> encrypts records
        </h3>
        <FamilyPill family="symmetric">{k.vault.latest_version_type}</FamilyPill>
      </div>
      <Versions k={k} />
      <Rotate keyName="ledger-data" targets={ENCRYPTION_TARGETS} suggested={nextEncryption(k.vault.latest_version_type)} onDone={reload} crossUsage="ed25519" action="agility.rotateLedger" />
      <form className="sign-form" onSubmit={doEnc}>
        <div className="form-field">
          <label htmlFor="ledger-label">Record to encrypt (synthetic)</label>
          <input id="ledger-label" value={label} onChange={(e) => setLabel(e.target.value)} maxLength={200} />
        </div>
        <div className="rotate__row">
          <button type="submit" className="primary-button" disabled={enc.busy || !label.trim()}>
            <Lock size={14} aria-hidden="true" /> {enc.busy ? 'Encrypting…' : 'Encrypt'}
            <Locked action="agility.encrypt" />
          </button>
          <button
            type="button"
            className="secondary-button"
            onClick={async () => {
              if (await rewrap.run()) {
                dec.clear();
                reload();
              }
            }}
            disabled={rewrap.busy || !data.ledger.length}
          >
            <RotateCw size={14} aria-hidden="true" /> {rewrap.busy ? 'Rewrapping…' : 'Rewrap all to the latest version'}
            <Locked action="agility.rewrap" />
          </button>
          <button type="button" className="secondary-button" onClick={() => dec.run()} disabled={dec.busy || !data.ledger.length}>
            <Unlock size={14} aria-hidden="true" /> Decrypt all
            <Locked action="agility.decrypt" />
          </button>
        </div>
      </form>
      <ErrorNotice error={enc.error || rewrap.error || dec.error} />
      {rewrap.result && (
        <p className="inline-notice" role="status">
          One batch call rewrapped {rewrap.result.rewrapped} record(s). Vault decrypted and re-encrypted inside itself: no plaintext in the answer.
        </p>
      )}
      {data.ledger.length > 0 && (
        <div className="table-scroll" tabIndex={0}>
          <table className="vg-table" aria-label="Encrypted records">
            <thead>
              <tr>
                <th scope="col">#</th>
                <th scope="col">Ciphertext</th>
                <th scope="col">Version</th>
                <th scope="col">Decrypted</th>
              </tr>
            </thead>
            <tbody>
              {data.ledger.map((e) => (
                <tr key={e.id}>
                  <td className="num">{e.id}</td>
                  <td>
                    <Mono title={e.ciphertext}>
                      <span className="cipher-prefix">{e.ciphertext.split(':').slice(0, 2).join(':')}:</span>
                      {short(e.ciphertext.split(':')[2], 18)}
                    </Mono>
                  </td>
                  <td>
                    v{e.version}
                    {e.rewrappedFrom ? <span className="dim"> (was v{e.rewrappedFrom})</span> : null}
                  </td>
                  <td>
                    {plain[e.id] ? (
                      plain[e.id].equal ? (
                        <StatePill state="ok">{plain[e.id].plaintext}</StatePill>
                      ) : (
                        <StatePill state="denied">{plain[e.id].error || 'differs'}</StatePill>
                      )
                    ) : (
                      <span className="dim">encrypted</span>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}

export default function Agility() {
  const r = useResource('agility', '/api/agility');
  const d = r.data;
  const s = d?.keys?.['orders-signing'];
  return (
    <>
      <section className="vg-hero hero-grid" aria-labelledby="ag-title">
        <div>
          <h2 id="ag-title" className="hero-title">
            Same key name, new algorithm
          </h2>
          <p className="hero-lede">
            Vault 2.2 rotates a Transit key to a different algorithm. The application keeps calling the same path; only Vault knows
            which version is post-quantum.
          </p>
          <p className="pinned">
            <span className="pinned__label">The caller is configured with</span>
            <Mono>{d?.callerConfig?.['orders-signing'] || 'transit/sign/orders-signing'}</Mono>
            <span className="pinned__label">and nothing else, from version 1 on.</span>
          </p>
        </div>
        <div className="hero-tiles">
          <div className="vg-tile">
            <span className="vg-tile__label">Versions</span>
            <span className="vg-tile__value">{s?.vault?.latest_version ?? '–'}</span>
            <span className="vg-tile__sub">of orders-signing</span>
          </div>
          <div className="vg-tile">
            <span className="vg-tile__label">Signing with</span>
            <span className="vg-tile__value hero-tile-text">{s?.vault?.latest_version_type || '–'}</span>
            <span className="vg-tile__sub">latest_version_type</span>
          </div>
          <div className="vg-tile vg-tile--gold">
            <span className="vg-tile__label">Signatures kept</span>
            <span className="vg-tile__value">{d ? d.signatures.length : '–'}</span>
            <span className="vg-tile__sub">verify any of them below</span>
          </div>
        </div>
      </section>
      <Authority actions={[['agility.read', 'read the keys'], ['agility.verify', 'verify'], ['agility.sign', 'sign'], ['agility.rotate', 'change algorithm'], ['agility.encrypt', 'encrypt'], ['agility.rewrap', 'rewrap'], ['agility.decrypt', 'decrypt']]} />
      <ErrorNotice error={r.error} title="Cannot read the demo keys" />
      {!d && !r.error && <Loading />}
      {d && (
        <div className="agility-grid">
          <Signing data={d} reload={r.reload} />
          <Ledger data={d} reload={r.reload} />
        </div>
      )}
      <aside className="vg-card note" aria-labelledby="ag-note">
        <h3 id="ag-note">What Vault reports, and what this page adds</h3>
        <p>
          Vault returns <Mono>latest_version_type</Mono> and keeps <Mono>type</Mono> at the original. For a signing key each version has a
          public key, so its algorithm can be read back (“derived”). For an encryption key Vault reports only a creation time per version; the
          algorithm of an older version is shown only if this API saw Vault’s answer when it made that version (“observed at rotation”).
          Rotations to a different usage, signing to encryption or back, are refused by Vault: try it. The encryption key stays symmetric:
          AES-256 and ChaCha20 keep a 128-bit margin against a quantum attacker, so its agility is about key size and cipher, not about
          leaving ECDSA.
        </p>
      </aside>
    </>
  );
}
