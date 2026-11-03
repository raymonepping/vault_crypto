// pages/QuantumPki.jsx — two chains side by side, one leaf from each, the
// bytes compared, both verified, OCSP asked, and the ML-DSA CA key moved.
import { useCallback, useState } from 'react';
import { RefreshCw, FilePlus2, Radio, MoveRight, Info, ListChecks, Ban } from 'lucide-react';
import { call } from '../api.js';
import { useAction, useResource } from '../hooks.js';
import { Authority, ByteBars, Check, Confirm, ErrorNotice, FamilyPill, Loading, Locked, Mono, StatePill, useAuth } from '../components/ui.jsx';
import { bytes, ratio, relative, short } from '../format.js';

const FAMILY = { classic: 'classic', pqc: 'post-quantum', moved: 'post-quantum' };

function Ladder({ chain }) {
  const rows = [
    { tier: 'Root', c: chain.root.certificate, extra: chain.root.issuerName },
    { tier: 'Intermediate', c: chain.intermediate.certificate, extra: chain.intermediate.issuerName },
  ];
  return (
    <ol className="ladder">
      {rows.map((r) => (
        <li key={r.tier} className="ladder__step">
          <span className="ladder__tier">{r.tier}</span>
          <span className="ladder__cn">{r.c.commonName}</span>
          <span className="ladder__meta">
            <FamilyPill family={r.c.key.family}>{r.c.key.label}</FamilyPill>
            <span className="dim">signed with {r.c.signatureAlgorithm.name}</span>
            <span className="dim">{bytes(r.c.bytes.der)}</span>
          </span>
        </li>
      ))}
      <li className="ladder__step ladder__step--role">
        <span className="ladder__tier">Role</span>
        <span className="ladder__cn">
          <Mono>{chain.intermediate.mount}/issue/service</Mono>
        </span>
        <span className="ladder__meta">
          <FamilyPill family={FAMILY[chain.id]}>{chain.role?.parameterSet ? chain.role.parameterSet.toUpperCase() : `EC ${chain.role?.keyBits === 256 ? 'P-256' : chain.role?.keyBits}`}</FamilyPill>
          <span className="dim">leaves, TTL {chain.role?.ttl}s</span>
          {chain.crl.ocspDisabled ? <StatePill state="warn">OCSP off</StatePill> : <StatePill state="ok">OCSP on</StatePill>}
        </span>
      </li>
    </ol>
  );
}

function Leaf({ r }) {
  const l = r.leaf;
  return (
    <div className="leaf" data-testid={`leaf-${r.chain}`}>
      <dl className="facts">
        <div>
          <dt>Common name</dt>
          <dd>{l.commonName}</dd>
        </div>
        <div>
          <dt>Serial</dt>
          <dd>
            <Mono>{short(l.serial, 29)}</Mono>
          </dd>
        </div>
        <div>
          <dt>Key</dt>
          <dd>
            <FamilyPill family={l.key.family}>{l.key.label}</FamilyPill>
          </dd>
        </div>
        <div>
          <dt>Signed with</dt>
          <dd>
            {l.signatureAlgorithm.name} <Mono>{l.signatureAlgorithm.oid}</Mono>
          </dd>
        </div>
        <div>
          <dt>Certificate</dt>
          <dd className="num">{bytes(l.bytes.der)} DER</dd>
        </div>
        <div>
          <dt>Issued in</dt>
          <dd className="num">{r.issueMs} ms</dd>
        </div>
      </dl>
      <ul className="verify-list" aria-label="Verification">
        <li>
          <Check ok={r.verification.node.ok} yes="Node verifies" no="Node rejects" />
          <span className="dim">{r.verification.node.runtime}</span>
        </li>
        <li>
          <Check ok={r.verification.openssl.ok} yes="OpenSSL verifies" no="OpenSSL rejects" />
          <Mono>{r.verification.openssl.output}</Mono>
        </li>
        <li>
          <StatePill state="info">private key</StatePill>
          <span className="dim">{r.privateKeyReturned}</span>
        </li>
      </ul>
    </div>
  );
}

// OCSP and the CRL side by side: the two ways a relying party learns that a
// certificate was revoked. The ML-DSA chain has only the second. Revoking
// here closes the loop: the leaf appears on the CRL (and, for the classic
// chain, OCSP turns "revoked").
function Revocation({ chain, mount, serial, commonName, ocspOn }) {
  const o = useAction(useCallback(() => call(`OCSP ${chain}`, `/api/pki/ocsp?chain=${chain}&serial=${encodeURIComponent(serial)}`), [chain, serial]));
  const c = useAction(useCallback(() => call(`CRL ${chain}`, `/api/pki/crl?chain=${chain}&serial=${encodeURIComponent(serial)}`), [chain, serial]));
  const rv = useAction(useCallback(() => call(`revoke ${serial}`, '/api/certs/revoke', { method: 'POST', body: { mount, serial } }), [mount, serial]));
  const [confirming, setConfirming] = useState(false);
  const r = o.result;
  const l = c.result;
  const revoke = async () => {
    const done = await rv.run();
    setConfirming(false);
    if (done) {
      c.run();
      if (ocspOn) o.run();
    }
  };
  return (
    <div className="ocsp">
      <div className="rotate__row">
        <button type="button" className="secondary-button" onClick={() => o.run()} disabled={o.busy}>
          <Radio size={14} aria-hidden="true" /> {o.busy ? 'Asking…' : 'Ask the OCSP responder'}
        </button>
        <button type="button" className="secondary-button" onClick={() => c.run()} disabled={c.busy}>
          <ListChecks size={14} aria-hidden="true" /> {c.busy ? 'Reading…' : 'Check the CRL'}
        </button>
        {!rv.result && (
          <button type="button" className="destructive-button" onClick={() => setConfirming(true)} disabled={rv.busy}>
            <Ban size={14} aria-hidden="true" /> Revoke this leaf
            <Locked action="certs.revoke" />
          </button>
        )}
      </div>
      <ErrorNotice error={o.error || c.error || rv.error} title={rv.error ? 'Vault refused the revocation' : undefined} />
      {rv.result && (
        <p className="inline-notice" role="status">
          Revoked {relative(rv.result.revocationTime)}. Vault rebuilt the CRL at once
          {rv.result.crl?.signatureAlgorithm ? `, signed with ${rv.result.crl.signatureAlgorithm}` : ''}.
        </p>
      )}
      {r && (
        <div className="ocsp__result" data-testid={`ocsp-${chain}`}>
          {r.status === 'good' || r.status === 'revoked' ? (
            <p>
              <strong>OCSP:</strong> <StatePill state={r.status === 'good' ? 'ok' : 'denied'}>{r.status}</StatePill> The response is signed
              with {r.signatureAlgorithm}, {r.signatureVerified ? 'and the signature verifies' : 'but the signature does NOT verify'}.
            </p>
          ) : (
            <>
              <p>
                <strong>OCSP:</strong> <StatePill state="denied">no answer</StatePill> Vault answered HTTP {r.httpStatus}, OCSP status{' '}
                <Mono>{r.responderError || r.status}</Mono>.
              </p>
              <p className="explain">
                <Info size={14} aria-hidden="true" />
                {ocspOn
                  ? 'The responder is on for this mount but did not answer.'
                  : 'The responder is off on this mount: Vault 2.2.1 cannot answer OCSP for an ML-DSA issuer (with it on, Vault returns HTTP 500, recorded by make probe). This chain publishes revocation in its CRL instead.'}
              </p>
            </>
          )}
        </div>
      )}
      {l && (
        <div className="ocsp__result" data-testid={`crl-${chain}`}>
          {l.available ? (
            <p>
              <strong>CRL:</strong>{' '}
              {l.listed ? <StatePill state="denied">revoked {relative(l.revokedAt)}</StatePill> : <StatePill state="ok">not revoked</StatePill>}{' '}
              This leaf {l.listed ? 'is' : 'is not'} on <Mono>{l.mount}/crl</Mono>: {l.entries} revoked{' '}
              {l.entries === 1 ? 'certificate' : 'certificates'}, signed with {l.signatureAlgorithm}, rebuilt {relative(l.lastUpdate)}, next
              update {relative(l.nextUpdate)}.
            </p>
          ) : (
            <p>
              <strong>CRL:</strong> <StatePill state="warn">not published</StatePill> <Mono>{l.mount}</Mono> has no CRL yet.
            </p>
          )}
        </div>
      )}
      <Confirm open={confirming} title="Revoke this leaf?" confirmLabel="Revoke" onConfirm={revoke} onCancel={() => setConfirming(false)} busy={rv.busy}>
        <p>
          <strong>{commonName}</strong> on <Mono>{mount}</Mono>, serial <Mono>{short(serial, 23)}</Mono>. Vault adds it to the CRL at once; it
          cannot be undone.
        </p>
      </Confirm>
    </div>
  );
}

function ChainColumn({ chain, onIssued, issued }) {
  const a = useAction(useCallback(() => call(`issue ${chain.id}`, '/api/pki/issue', { method: 'POST', body: { chain: chain.id, cn: `${chain.id}-orders.lab.local` } }), [chain.id]));
  const run = async () => {
    const r = await a.run();
    if (r) onIssued(chain.id, r);
  };
  return (
    <section className="vg-card chain" aria-labelledby={`chain-${chain.id}`}>
      <div className="chain__head">
        <h3 id={`chain-${chain.id}`}>{chain.label}</h3>
        <FamilyPill family={FAMILY[chain.id]} />
      </div>
      <Ladder chain={chain} />
      <button type="button" className="primary-button" onClick={run} disabled={a.busy}>
        <FilePlus2 size={14} aria-hidden="true" /> {a.busy ? 'Issuing…' : 'Issue a leaf'}
        <Locked action={`pki.issue.${chain.id}`} />
      </button>
      <ErrorNotice error={a.error} />
      {issued && (
        <>
          <Leaf r={issued} />
          <Revocation key={issued.leaf.serial} chain={chain.id} mount={chain.intermediate.mount} serial={issued.leaf.serial} commonName={issued.leaf.commonName} ocspOn={!chain.crl.ocspDisabled} />
        </>
      )}
    </section>
  );
}

function Move() {
  const ev = useResource('move evidence', '/api/pki/move', { quiet: false });
  const [moved, setMoved] = useState(null);
  const issue = useAction(useCallback(() => call('issue moved', '/api/pki/issue', { method: 'POST', body: { chain: 'moved', cn: 'moved-orders.lab.local' } }), []));
  const e = ev.data;
  const run = async () => setMoved(await issue.run());
  return (
    <section className="vg-card move" aria-labelledby="move-title">
      <div className="chain__head">
        <h3 id="move-title">Move the ML-DSA issuing key</h3>
        {e && (e.moved ? <StatePill state="ok">moved</StatePill> : <StatePill state="warn">not moved yet</StatePill>)}
        <button type="button" className="vg-btn vg-btn--ghost" onClick={ev.reload} aria-label="Refresh the move evidence">
          <RefreshCw size={14} aria-hidden="true" /> Refresh
        </button>
      </div>
      <p className="explain">
        Vault Enterprise 2.2 exports a CA key only wrapped, to a public key the target mount generated. Here the wrap is ML-KEM-1024, so
        the post-quantum key never travels under classic cryptography. Export needs <Mono>sudo</Mono> on the path, which this console’s
        token does not have: an operator runs <Mono>{e?.command || 'make pki-move'}</Mono>, and this card shows what Vault recorded.
      </p>
      <ErrorNotice error={ev.error} />
      {!e && !ev.error && <Loading />}
      {e && (
        <ol className="move-steps">
          <li>
            <span className="move-steps__n">1</span>
            <div>
              <strong>Source</strong> <Mono>{e.source.mount}</Mono> key <Mono>{short(e.source.keyId, 13)}</Mono>{' '}
              <FamilyPill family="post-quantum">{(e.source.parameterSet || e.source.keyType || '').toUpperCase()}</FamilyPill>
            </div>
          </li>
          <li>
            <span className="move-steps__n">2</span>
            <div>
              <strong>Export key on the target</strong>{' '}
              {e.target.exportKeys.length ? (
                e.target.exportKeys.map((k) => (
                  <span key={k.exportKeyUuid}>
                    <FamilyPill family="post-quantum">{k.keyType || 'ML-KEM'}</FamilyPill> <Mono>{short(k.exportKeyHmac, 22)}</Mono>
                  </span>
                ))
              ) : (
                <span className="dim">none yet</span>
              )}
            </div>
          </li>
          <li>
            <span className="move-steps__n">3</span>
            <div>
              <strong>Recorded on the source issuer</strong>{' '}
              {e.source.exportWarnings.length ? (
                <ul className="warn-list">
                  {e.source.exportWarnings.map((w) => (
                    <li key={w}>
                      <StatePill state="warn">exported</StatePill> <Mono>{w}</Mono>
                    </li>
                  ))}
                </ul>
              ) : (
                <span className="dim">no export recorded</span>
              )}
            </div>
          </li>
          <li>
            <span className="move-steps__n">4</span>
            <div>
              <strong>Imported on</strong> <Mono>{e.target.mount}</Mono>{' '}
              {e.target.keys.length ? (
                e.target.keys.map((k) => (
                  <span key={k.keyId}>
                    key <Mono>{short(k.keyId, 13)}</Mono> <FamilyPill family="post-quantum">{(k.parameterSet || k.keyType).toUpperCase()}</FamilyPill>
                  </span>
                ))
              ) : (
                <span className="dim">empty</span>
              )}
            </div>
          </li>
        </ol>
      )}
      {e?.moved && (
        <>
          <button type="button" className="primary-button" onClick={run} disabled={issue.busy}>
            <MoveRight size={14} aria-hidden="true" /> {issue.busy ? 'Issuing…' : 'Issue from the moved key'}
            <Locked action="pki.issue.moved" />
          </button>
          <ErrorNotice error={issue.error} />
          {moved && <Leaf r={moved} />}
        </>
      )}
    </section>
  );
}

export default function QuantumPki() {
  const me = useAuth();
  const chains = useResource('chains', '/api/pki/chains');
  const [issued, setIssued] = useState({});
  const onIssued = (id, r) => setIssued((s) => ({ ...s, [id]: r }));
  const c = issued.classic?.leaf;
  const p = issued.pqc?.leaf;

  return (
    <>
      <section className="vg-hero hero-grid" aria-labelledby="pki-title">
        <div>
          <h2 id="pki-title" className="hero-title">
            What does post-quantum cost a certificate?
          </h2>
          <p className="hero-lede">
            Both chains live in the same Vault, with the same roles and lifetimes. Only the algorithm differs: ECDSA on the left, ML-DSA (FIPS
            204) on the right.
          </p>
        </div>
        <div className="hero-tiles">
          <div className="vg-tile">
            <span className="vg-tile__label">Leaf certificate</span>
            <span className="vg-tile__value">{c && p ? ratio(p.bytes.der, c.bytes.der) : '–'}</span>
            <span className="vg-tile__sub">{c && p ? `${bytes(p.bytes.der)} vs ${bytes(c.bytes.der)}` : 'issue a leaf on both sides'}</span>
          </div>
          <div className="vg-tile">
            <span className="vg-tile__label">Signature</span>
            <span className="vg-tile__value">{c && p ? ratio(p.bytes.signature, c.bytes.signature) : '–'}</span>
            <span className="vg-tile__sub">{c && p ? `${p.bytes.signature} B vs ${c.bytes.signature} B` : 'measured from the DER'}</span>
          </div>
          <div className="vg-tile">
            <span className="vg-tile__label">Public key</span>
            <span className="vg-tile__value">{c && p ? ratio(p.bytes.publicKey, c.bytes.publicKey) : '–'}</span>
            <span className="vg-tile__sub">{c && p ? `${p.bytes.publicKey} B vs ${c.bytes.publicKey} B` : 'SubjectPublicKeyInfo'}</span>
          </div>
        </div>
      </section>

      <Authority actions={[['certs.read', 'read the chains'], ['pki.issue.classic', 'issue ECDSA'], ['pki.issue.pqc', 'issue ML-DSA'], ['pki.issue.moved', 'issue from the moved key'], ['certs.revoke', 'revoke']]} />
      <ErrorNotice error={chains.error} title="Cannot read the chains" />
      {!chains.data && !chains.error && <Loading />}
      {chains.data && (
        <div className="chain-grid">
          <ChainColumn chain={chains.data.chains.classic} issued={issued.classic} onIssued={onIssued} />
          <ChainColumn chain={chains.data.chains.pqc} issued={issued.pqc} onIssued={onIssued} />
        </div>
      )}

      {c && p && (
        <section className="vg-card" aria-labelledby="cmp-title">
          <h3 id="cmp-title">The two leaves, byte for byte</h3>
          <ByteBars
            rows={[
              { label: 'Certificate (DER)', values: [{ key: 'ECDSA', value: c.bytes.der, family: 'classic' }, { key: 'ML-DSA', value: p.bytes.der, family: 'post-quantum' }] },
              { label: 'Signature', values: [{ key: 'ECDSA', value: c.bytes.signature, family: 'classic' }, { key: 'ML-DSA', value: p.bytes.signature, family: 'post-quantum' }] },
              { label: 'Public key', values: [{ key: 'ECDSA', value: c.bytes.publicKey, family: 'classic' }, { key: 'ML-DSA', value: p.bytes.publicKey, family: 'post-quantum' }] },
            ]}
          />
          <p className="explain">
            The ML-DSA leaf carries an ML-DSA-44 public key and an ML-DSA-65 signature from its intermediate; the ECDSA leaf a P-256 key and
            a P-256 signature. A TLS handshake sends the leaf and the intermediate, so the chain on the wire grows by the same factor.
          </p>
        </section>
      )}

      {me.signedIn && <Move />}

      <aside className="vg-card note" aria-labelledby="note-title">
        <h3 id="note-title">Why this page itself is served with ECDSA</h3>
        <p>
          Browsers do not accept ML-DSA certificate signatures yet. The console’s own TLS certificate comes from the classic chain
          (<Mono>pki-classic-int/issue/web</Mono>), renewed by Vault Agent. Post-quantum certificates today are for the machine-to-machine
          paths you control: service mesh, mTLS between your own services, code signing.
        </p>
      </aside>
    </>
  );
}
