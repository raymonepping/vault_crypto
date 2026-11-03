// pages/Fpe.jsx — FF1 on synthetic card numbers, Dutch IBANs and BSNs:
// encode, decode, and rewrap the cards to a new transformation in one call.
import { useCallback, useState } from 'react';
import { Lock, Unlock, RotateCw, Undo2 } from 'lucide-react';
import { call } from '../api.js';
import { useAction, useResource } from '../hooks.js';
import { Authority, ErrorNotice, Loading, Locked, Mono, StatePill } from '../components/ui.jsx';

const KIND_LABEL = { card: 'Card number', iban: 'Dutch IBAN', bsn: 'BSN' };
// How often a random value of that shape passes its checksum anyway.
const CHANCE = { Luhn: '1 in 10', 'mod-97': '1 in 97', elfproef: '1 in 11' };

export default function Fpe() {
  const r = useResource('fpe', '/api/fpe');
  // id → { encoded, transformation, check, decoded, matches }
  const [rows, setRows] = useState({});
  const merge = (items, fn) => setRows((s) => ({ ...s, ...Object.fromEntries(items.map((it) => [it.id, { ...s[it.id], ...fn(it) }])) }));

  const encode = useAction(useCallback((items) => call('encode all', '/api/fpe/encode', { method: 'POST', body: { items } }), []));
  const decode = useAction(useCallback((items) => call('decode all', '/api/fpe/decode', { method: 'POST', body: { items } }), []));
  const rewrap = useAction(useCallback((items) => call('rewrap cards', '/api/fpe/rewrap', { method: 'POST', body: { items } }), []));

  const d = r.data;
  const fixtures = d?.fixtures || [];
  const encodedItems = fixtures.filter((f) => rows[f.id]?.encoded).map((f) => ({ id: f.id, value: rows[f.id].encoded, transformation: rows[f.id].transformation }));

  const doEncode = async () => {
    const res = await encode.run(fixtures.map((f) => ({ id: f.id })));
    if (res) merge(res.items, (it) => ({ encoded: it.output, transformation: it.transformation, check: it.check, decoded: null, matches: null, rewrapped: false }));
  };
  const doDecode = async () => {
    const res = await decode.run(encodedItems);
    if (res) merge(res.items, (it) => ({ decoded: it.output, matches: it.matchesFixture }));
  };
  const doRewrap = async () => {
    const res = await rewrap.run(encodedItems.filter((x) => x.id.startsWith('card')));
    if (res) merge(res.items, (it) => ({ previous: rows[it.id]?.encoded, encoded: it.output, transformation: it.transformation, check: it.check, decoded: null, matches: null, rewrapped: true }));
  };
  const busy = encode.busy || decode.busy || rewrap.busy;
  const anyEncoded = encodedItems.length > 0;
  const cardsLegacy = encodedItems.some((x) => x.id.startsWith('card') && x.transformation === d?.rewrap?.from);

  return (
    <>
      <section className="vg-hero hero-grid" aria-labelledby="fpe-title">
        <div>
          <h2 id="fpe-title" className="hero-title">
            Encrypted, and still the right shape
          </h2>
          <p className="hero-lede">
            Format-preserving encryption turns a card number into another 16-digit card number, an IBAN into an IBAN. Databases, forms and
            masks keep working. On Vault 2.2 every new FPE transformation is FF1 (NIST SP 800-38G).
          </p>
        </div>
        <div className="hero-tiles hero-tiles--two">
          {d &&
            Object.values(d.transformations).map((t) => (
              <div className="vg-tile" key={t.name}>
                <span className="vg-tile__label">{t.name}</span>
                <span className="vg-tile__value hero-tile-text">{t.fpe_algorithm?.toUpperCase() || '–'}</span>
                <span className="vg-tile__sub">{t.template}</span>
              </div>
            ))}
        </div>
      </section>

      <Authority actions={[['fpe.read', 'read transformations'], ['fpe.encode', 'encode'], ['fpe.decode', 'decode'], ['fpe.rewrap', 'rewrap']]} />
      <ErrorNotice error={r.error} title="Cannot read the transformations" />
      {!d && !r.error && <Loading />}

      {d && (
        <section className="vg-card" aria-labelledby="fx-title">
          <div className="chain__head">
            <h3 id="fx-title">Synthetic fixtures</h3>
            <span className="dim">
              role <Mono>{d.role}</Mono>, all generated: published test card numbers, IBANs with bank code TEST, BSNs made to pass the elfproef
            </span>
          </div>
          <div className="rotate__row">
            <button type="button" className="primary-button" onClick={doEncode} disabled={busy}>
              <Lock size={14} aria-hidden="true" /> {encode.busy ? 'Encoding…' : 'Encode all'}
              <Locked action="fpe.encode" />
            </button>
            <button type="button" className="secondary-button" onClick={doDecode} disabled={busy || !anyEncoded}>
              <Unlock size={14} aria-hidden="true" /> Decode all
              <Locked action="fpe.decode" />
            </button>
            <button type="button" className="secondary-button" onClick={doRewrap} disabled={busy || !cardsLegacy}>
              <RotateCw size={14} aria-hidden="true" /> Rewrap cards {d.rewrap.from} → {d.rewrap.to}
              <Locked action="fpe.rewrap" />
            </button>
            <button type="button" className="vg-btn vg-btn--ghost" onClick={() => setRows({})} disabled={busy || !anyEncoded}>
              <Undo2 size={14} aria-hidden="true" /> Clear
            </button>
          </div>
          <ErrorNotice error={encode.error || decode.error || rewrap.error} />
          {rewrap.result && (
            <p className="inline-notice" role="status">
              One batch call moved {rewrap.result.items.length} card numbers from <Mono>{rewrap.result.from}</Mono> to <Mono>{rewrap.result.to}</Mono>.
              Vault decoded and re-encoded inside itself; the plaintext never left it.
            </p>
          )}
          <div className="table-scroll" tabIndex={0}>
            <table className="vg-table fpe-table" aria-label="Fixtures and their FF1 encodings">
              <thead>
                <tr>
                  <th scope="col">Kind</th>
                  <th scope="col">Plaintext</th>
                  <th scope="col">Transformation</th>
                  <th scope="col">Encoded</th>
                  <th scope="col">Shape</th>
                  <th scope="col">Checksum</th>
                  <th scope="col">Decoded</th>
                </tr>
              </thead>
              <tbody>
                {fixtures.map((f) => {
                  const s = rows[f.id] || {};
                  return (
                    <tr key={f.id} data-testid={`fx-${f.id}`}>
                      <td>{KIND_LABEL[f.kind]}</td>
                      <td>
                        <Mono>{f.value}</Mono>
                      </td>
                      <td>
                        <Mono>{s.transformation || f.transformation}</Mono>
                      </td>
                      <td>
                        {s.encoded ? (
                          <>
                            <Mono>{s.encoded}</Mono>
                            {s.rewrapped && s.previous ? (
                              <span className="dim was">
                                was <Mono>{s.previous}</Mono>
                              </span>
                            ) : null}
                          </>
                        ) : (
                          <span className="dim">not encoded</span>
                        )}
                      </td>
                      <td>{s.check ? s.check.shape ? <StatePill state="ok">kept</StatePill> : <StatePill state="denied">changed</StatePill> : <span className="dim">–</span>}</td>
                      <td>
                        {s.check ? (
                          s.check.checksum ? (
                            <span title={`By chance: about ${CHANCE[s.check.checksumName]} encoded values passes the ${s.check.checksumName}. FF1 does not recompute check digits.`}>
                              <StatePill state="ok">{s.check.checksumName} valid by chance</StatePill>
                            </span>
                          ) : (
                            <StatePill state="warn">{s.check.checksumName} not kept</StatePill>
                          )
                        ) : (
                          <span className="dim">–</span>
                        )}
                      </td>
                      <td>
                        {s.decoded ? s.matches ? <StatePill state="ok">equals the fixture</StatePill> : <StatePill state="denied">{s.decoded}</StatePill> : <span className="dim">–</span>}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </section>
      )}

      <aside className="vg-card note" aria-labelledby="fpe-note">
        <h3 id="fpe-note">What FF1 keeps, and what it does not</h3>
        <p>
          The length, the alphabet and every character the template leaves alone survive: <Mono>NL</Mono>, the check digits and the bank
          code of an IBAN are not encrypted, only the account number is. Check digits are not recomputed, so an encoded value usually fails
          Luhn, mod-97 or the elfproef; a system that validates checksums on write needs to know that. FPE has no integrity tag: decoding a
          value with the wrong transformation returns a different, equally plausible number, not an error.
        </p>
        <p>
          Vault 2.2 deprecates FF3-1. On 2.2.1 a request for an FF3-1 transformation is accepted and silently made FF1 (the probe recorded
          it), so this room rewraps between two FF1 transformations with different keys: the same <Mono>transform/rewrap</Mono> call that
          migrates FF3-1 data written by an older Vault.
        </p>
      </aside>
    </>
  );
}
