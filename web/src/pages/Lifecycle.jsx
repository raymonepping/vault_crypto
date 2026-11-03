// pages/Lifecycle.jsx — every certificate on the three issuing mounts, by
// algorithm and status, with revocation and links into Vault's own UI.
import { useCallback, useMemo, useState } from 'react';
import { ExternalLink, RefreshCw } from 'lucide-react';
import { call } from '../api.js';
import { useAction, useResource } from '../hooks.js';
import { Authority, Confirm, ErrorNotice, FamilyPill, Loading, Locked, Mono, StatePill } from '../components/ui.jsx';
import { relative, short, when } from '../format.js';

const MOUNTS = ['pki-classic-int', 'pki-pqc-int', 'pki-pqc-next'];

function status(c) {
  if (c.revoked) return { state: 'denied', label: 'revoked' };
  if (c.expired) return { state: 'warn', label: 'expired' };
  return { state: 'ok', label: 'valid' };
}

export default function Lifecycle() {
  const inv = useResource('inventory', '/api/certs');
  const [q, setQ] = useState('');
  const [mount, setMount] = useState('');
  const [family, setFamily] = useState('');
  const [state, setState] = useState('');
  const [target, setTarget] = useState(null);
  const revoke = useAction(useCallback((t) => call(`revoke ${t.serial}`, '/api/certs/revoke', { method: 'POST', body: { mount: t.mount, serial: t.serial } }), []));

  const d = inv.data;
  const certs = useMemo(() => {
    const needle = q.trim().toLowerCase();
    return (d?.certs || []).filter(
      (c) =>
        (!mount || c.mount === mount) &&
        (!family || c.family === family) &&
        (!state || status(c).label === state) &&
        (!needle || c.commonName?.toLowerCase().includes(needle) || c.serial.includes(needle)),
    );
  }, [d, q, mount, family, state]);
  const all = d?.certs || [];
  const count = (fn) => all.filter(fn).length;

  const confirm = async () => {
    if (await revoke.run(target)) {
      setTarget(null);
      inv.reload();
    }
  };

  return (
    <>
      <section className="vg-hero hero-grid" aria-labelledby="lc-title">
        <div>
          <h2 id="lc-title" className="hero-title">
            Every certificate, both worlds
          </h2>
          <p className="hero-lede">
            Classic and post-quantum certificates in one inventory, revoked through the same call and published on CRLs that each issuer signs
            with its own algorithm.
          </p>
          {d && (
            <a className="hero-link" href={d.vaultUi} target="_blank" rel="noreferrer">
              <ExternalLink size={14} aria-hidden="true" /> The same certificates in Vault’s UI
            </a>
          )}
        </div>
        <div className="hero-tiles">
          <div className="vg-tile">
            <span className="vg-tile__label">Certificates</span>
            <span className="vg-tile__value">{d ? all.length : '–'}</span>
            <span className="vg-tile__sub">on three issuing mounts</span>
          </div>
          <div className="vg-tile">
            <span className="vg-tile__label">Post-quantum</span>
            <span className="vg-tile__value">{d ? count((c) => c.family === 'post-quantum') : '–'}</span>
            <span className="vg-tile__sub">ML-DSA keys</span>
          </div>
          <div className="vg-tile vg-tile--gold">
            <span className="vg-tile__label">Revoked</span>
            <span className="vg-tile__value">{d ? count((c) => c.revoked) : '–'}</span>
            <span className="vg-tile__sub">listed on the CRLs</span>
          </div>
        </div>
      </section>

      <Authority actions={[['certs.read', 'read the inventory'], ['certs.revoke', 'revoke']]} />
      <ErrorNotice error={inv.error} title="Cannot read the inventory" />
      {!d && !inv.error && <Loading />}

      {d && (
        <section className="crl-grid" aria-label="Certificate revocation lists">
          {d.crl.map((c) => (
            <div className="vg-card crl" key={c.mount}>
              <h3>
                <Mono>{c.mount}</Mono> CRL
              </h3>
              {c.available ? (
                <dl className="facts facts--tight">
                  <div>
                    <dt>Signed with</dt>
                    <dd>{c.signatureAlgorithm}</dd>
                  </div>
                  <div>
                    <dt>Updated</dt>
                    <dd>{relative(c.lastUpdate)}</dd>
                  </div>
                  <div>
                    <dt>Entries</dt>
                    <dd className="num">{c.entries}</dd>
                  </div>
                </dl>
              ) : (
                <p className="dim">No CRL yet (the mount has no issuer).</p>
              )}
            </div>
          ))}
        </section>
      )}

      {d && (
        <section className="vg-card" aria-labelledby="inv-title">
          <div className="chain__head">
            <h3 id="inv-title">Inventory</h3>
            <button type="button" className="vg-btn vg-btn--ghost" onClick={inv.reload}>
              <RefreshCw size={14} aria-hidden="true" /> Refresh
            </button>
          </div>
          <div className="filter-bar">
            <label className="sr-only" htmlFor="inv-q">
              Search by common name or serial
            </label>
            <input id="inv-q" type="search" placeholder="Search common name or serial" value={q} onChange={(e) => setQ(e.target.value)} />
            <label className="sr-only" htmlFor="inv-mount">
              Mount
            </label>
            <select id="inv-mount" value={mount} onChange={(e) => setMount(e.target.value)}>
              <option value="">All mounts</option>
              {MOUNTS.map((m) => (
                <option key={m} value={m}>
                  {m}
                </option>
              ))}
            </select>
            <label className="sr-only" htmlFor="inv-family">
              Algorithm family
            </label>
            <select id="inv-family" value={family} onChange={(e) => setFamily(e.target.value)}>
              <option value="">Both families</option>
              <option value="post-quantum">post-quantum</option>
              <option value="classic">classic</option>
            </select>
            <label className="sr-only" htmlFor="inv-state">
              Status
            </label>
            <select id="inv-state" value={state} onChange={(e) => setState(e.target.value)}>
              <option value="">Any status</option>
              <option value="valid">valid</option>
              <option value="revoked">revoked</option>
              <option value="expired">expired</option>
            </select>
            <span>
              {certs.length} of {all.length}
              {d.truncated ? ` (capped at ${d.cap.perMount} per mount: ${d.cap.selection})` : ''}
            </span>
          </div>
          <ErrorNotice error={revoke.error} title="Vault refused the revocation" />
          {certs.length === 0 ? (
            <div className="state-empty">
              <h3>No certificate matches</h3>
              <p>Issue one in Quantum PKI, or clear the filters.</p>
            </div>
          ) : (
            <div className="table-scroll" tabIndex={0}>
              <table className="vg-table" aria-label="Certificates">
                <thead>
                  <tr>
                    <th scope="col">Common name</th>
                    <th scope="col">Mount</th>
                    <th scope="col">Key</th>
                    <th scope="col">Signed with</th>
                    <th scope="col">Expires</th>
                    <th scope="col">Status</th>
                    <th scope="col">
                      <span className="sr-only">Actions</span>
                    </th>
                  </tr>
                </thead>
                <tbody>
                  {certs.map((c) => {
                    const s = status(c);
                    return (
                      <tr key={`${c.mount}-${c.serial}`} className={c.revoked ? 'row--revoked' : undefined} data-testid={`cert-${c.serial}`}>
                        <td>
                          {c.commonName || <span className="dim">(no CN)</span>}
                          <div>
                            <Mono title={c.serial}>{short(c.serial, 23)}</Mono>
                          </div>
                        </td>
                        <td>
                          <Mono>{c.mount}</Mono>
                        </td>
                        <td>
                          <FamilyPill family={c.family}>{c.keyType}</FamilyPill>
                        </td>
                        <td>{c.signatureAlgorithm}</td>
                        <td title={when(c.notAfter)}>{relative(c.notAfter)}</td>
                        <td>
                          <StatePill state={s.state}>{s.label}</StatePill>
                        </td>
                        <td className="row-actions">
                          <a href={c.vaultUi} target="_blank" rel="noreferrer" aria-label={`Open ${c.commonName} in Vault UI`}>
                            <ExternalLink size={14} aria-hidden="true" />
                          </a>
                          {!c.revoked && (
                            <button type="button" className="text-danger" onClick={() => setTarget(c)}>
                              Revoke
                              <Locked action="certs.revoke" />
                            </button>
                          )}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
        </section>
      )}

      <Confirm open={Boolean(target)} title="Revoke this certificate?" confirmLabel="Revoke" onConfirm={confirm} onCancel={() => setTarget(null)} busy={revoke.busy}>
        {target && (
          <p>
            <strong>{target.commonName}</strong> on <Mono>{target.mount}</Mono>, serial <Mono>{short(target.serial, 23)}</Mono>. Vault adds it to
            the CRL at once; it cannot be undone.
          </p>
        )}
      </Confirm>
    </>
  );
}
