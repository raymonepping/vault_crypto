// pages/Overview.jsx — what Vault 2.2 adds, and whether each room can run here.
import { ShieldCheck, Shuffle, Binary, ListChecks, ArrowRight } from 'lucide-react';
import { useResource } from '../hooks.js';
import { ErrorNotice, Loading, StatePill, Mono } from '../components/ui.jsx';
import { date } from '../format.js';

const ROOMS = [
  {
    id: 'pki',
    key: 'pki',
    icon: ShieldCheck,
    title: 'Quantum PKI',
    feature: 'ML-DSA certificates in the PKI secrets engine, and CA key export wrapped under ML-KEM',
    see: 'Issue a leaf from a classic ECDSA chain and from an ML-DSA chain, compare the bytes, verify both, then move the ML-DSA issuing key to another mount.',
  },
  {
    id: 'agility',
    key: 'agility',
    icon: Shuffle,
    title: 'Crypto agility',
    feature: 'Transit: rotate a key to a different algorithm (transit/keys/:name/algorithm)',
    see: 'One key name goes from ECDSA P-256 to ML-DSA to a hybrid. Old signatures keep verifying and the caller never changes its configuration.',
  },
  {
    id: 'fpe',
    key: 'fpe',
    icon: Binary,
    title: 'Format-preserving encryption',
    feature: 'Transform: FF1 for every new FPE transformation, and a rewrap endpoint',
    see: 'Synthetic card numbers, Dutch IBANs and BSNs keep their format when encrypted, and move to a new transformation in one call.',
  },
  {
    id: 'lifecycle',
    key: 'lifecycle',
    icon: ListChecks,
    title: 'Certificate lifecycle',
    feature: 'One inventory across classic and post-quantum issuers',
    see: 'Every certificate the lab issued, by algorithm and status, with revocation on ML-DSA-signed CRLs and links into Vault’s own certificate view.',
  },
];

export default function Overview() {
  const health = useResource('health', '/api/health');
  const caps = useResource('capabilities', '/api/capabilities');
  const h = health.data;
  const c = caps.data;

  return (
    <>
      <section className="vg-hero hero-grid" aria-labelledby="ov-title">
        <div>
          <h2 id="ov-title" className="hero-title">
            Vault 2.2, crypto agility
          </h2>
          <p className="hero-lede">
            One Vault Enterprise node, auto-unsealed by a seal Vault. Four rooms, one feature each. Every number on these pages is
            measured on what Vault just returned.
          </p>
        </div>
        <div className="hero-tiles">
          <div className="vg-tile">
            <span className="vg-tile__label">vault-1</span>
            <span className="vg-tile__value hero-tile-text">{h?.vault?.version || '–'}</span>
            <span className="vg-tile__sub">{h ? (h.vault.sealed ? 'sealed' : 'unsealed, transit seal') : 'checking'}</span>
          </div>
          <div className="vg-tile">
            <span className="vg-tile__label">Seal Vault</span>
            <span className="vg-tile__value hero-tile-text">{h?.seal?.version || '–'}</span>
            <span className="vg-tile__sub">{h ? (h.seal.sealed ? 'sealed' : 'unsealed, Shamir') : 'checking'}</span>
          </div>
          <div className="vg-tile vg-tile--gold">
            <span className="vg-tile__label">Licence until</span>
            <span className="vg-tile__value hero-tile-text">{date(c?.license?.expirationTime)}</span>
            <span className="vg-tile__sub">{c?.license?.features ? `${c.license.features.length} features` : 'checking'}</span>
          </div>
        </div>
      </section>

      <ErrorNotice error={health.error || caps.error} title="The API cannot reach Vault" />
      {!c && !caps.error && <Loading />}

      <section className="room-grid" aria-label="Rooms">
        {ROOMS.map((r) => {
          const room = c?.rooms?.[r.key];
          const Icon = r.icon;
          return (
            <article key={r.id} className="vg-card room-card">
              <div className="room-card__head">
                <span className="room-card__icon">
                  <Icon aria-hidden="true" />
                </span>
                <h3>{r.title}</h3>
                {room ? (
                  room.available ? (
                    <StatePill state="ok">available</StatePill>
                  ) : (
                    <StatePill state="denied">{room.licensed ? 'not configured' : 'not licensed'}</StatePill>
                  )
                ) : null}
              </div>
              <p className="room-card__feature">{r.feature}</p>
              <p className="room-card__see">{r.see}</p>
              {room && !room.available && (
                <p className="room-card__why">
                  Needs {room.needs}. {room.config?.error ? <>Vault said: <Mono>{room.config.error}</Mono></> : null}
                </p>
              )}
              <a className="secondary-button room-card__go" href={`#/${r.id}`}>
                Open {r.title} <ArrowRight size={14} aria-hidden="true" />
              </a>
            </article>
          );
        })}
      </section>

      <section className="vg-card how" aria-labelledby="how-title">
        <h3 id="how-title">How this lab is built</h3>
        <ul>
          <li>
            <Mono>vault-s</Mono> (Community, Shamir) holds one Transit key; <Mono>vault-1</Mono> (Enterprise) auto-unseals with it through a
            Vault Agent token.
          </li>
          <li>Terraform owns the configuration: both CA chains, the Transit and Transform mounts, policies and AppRoles.</li>
          <li>
            The keys whose algorithm the demo changes are runtime state. <Mono>make demo-reset</Mono> puts every room back where it started.
          </li>
          <li>
            Every room action runs on a Vault token issued to the person who signed in; the console's own token only reads platform facts.
            Nobody can export a CA key here: <Mono>make pki-move</Mono> is an operator action.
          </li>
          <li>
            The API runs Node {h?.runtime?.node || '–'} with {h?.runtime?.openssl?.split(' ').slice(0, 2).join(' ') || 'OpenSSL'}. ML-DSA certificates need
            OpenSSL 3.5 or later to parse and verify.
          </li>
        </ul>
      </section>
    </>
  );
}
