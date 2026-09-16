"""Network/fallback regression tests with synthetic DNS and install attempts."""
import os
import unittest

from test_installer import bash


# dig mock keeps real parsing, snapshot aggregation and wait_dns logic in use.
DNS_MOCK = r'''
log(){ :; }
info(){ :; }
warn(){ printf '%s\n' "$*"; }
trap 'printf "UNEXPECTED_ERR_TRAP\n" >&2; exit 99' ERR
dig(){
  local server="" kind="${@: -1}" domain="${@: -2:1}" item flags="qr rd ra" data="" status=NOERROR
  for item in "$@"; do [[ "$item" != @* ]] || server="${item#@}"; done
  if [[ "$kind" == NS ]]; then
    if [[ "$domain" == example.test ]]; then
      data=$'example.test. 60 IN NS ns1.example.test.\nexample.test. 60 IN NS ns2.example.test.'
    fi
  else
    if [[ "$server" == ns*.example.test ]]; then flags="qr aa"; fi
    if [[ "$kind" == A ]]; then data="$domain. 60 IN A 192.0.2.10"; fi
    case "$SCENARIO:$server:$kind" in
      timeout:ns2.example.test:*|all-timeout:ns*.example.test:*|public-timeout:9.9.9.9:*|v6-timeout:ns2.example.test:AAAA)
        printf ';; communications error: timed out\n'; return 9 ;;
      wrong-a:ns2.example.test:A|mixed:ns2.example.test:A|public-wrong:8.8.8.8:A)
        data="$domain. 60 IN A 192.0.2.99" ;;
      mixed:ns2.example.test:AAAA) return 9 ;;
      ipv6:ns2.example.test:AAAA|public-ipv6:9.9.9.9:AAAA)
        data="$domain. 60 IN AAAA 2001:db8::1" ;;
      servfail:ns2.example.test:*) status=SERVFAIL; data="" ;;
      nxdomain:ns2.example.test:*) status=NXDOMAIN; data="" ;;
      nonauthoritative:ns2.example.test:*) flags="qr rd ra" ;;
      malformed:ns2.example.test:*) echo 'garbage'; return 0 ;;
      cname:ns2.example.test:A) data="$domain. 60 IN CNAME other.example.test." ;;
    esac
  fi
  printf ';; ->>HEADER<<- opcode: QUERY, status: %s, id: 123\n' "$status"
  printf ';; flags: %s; QUERY: 1, ANSWER: 1\n' "$flags"
  if [[ -n "$data" ]]; then printf '%s\n' "$data"; fi
  return 0
}
'''


class DNSTests(unittest.TestCase):
    def test_dns_evidence_matrix(self):
        expected = {
            'ok': 'full', 'timeout': 'partial', 'v6-timeout': 'partial',
            'all-timeout': 'blocked', 'public-timeout': 'blocked',
            'wrong-a': 'blocked', 'mixed': 'blocked', 'ipv6': 'blocked',
            'public-wrong': 'blocked', 'public-ipv6': 'blocked',
            'servfail': 'blocked', 'nxdomain': 'blocked',
            'nonauthoritative': 'blocked', 'malformed': 'blocked', 'cname': 'blocked',
        }
        for scenario, state in expected.items():
            with self.subTest(scenario=scenario):
                r = bash(DNS_MOCK + '''
                  dns_snapshot s.example.test 192.0.2.10
                  print_dns
                  if dns_ready; then echo RESULT=full
                  elif dns_partial_ready; then echo RESULT=partial
                  else echo RESULT=blocked; fi
                ''', env=dict(os.environ, SCENARIO=scenario))
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn('RESULT=' + state, r.stdout)
                self.assertNotIn('UNEXPECTED_ERR_TRAP', r.stdout + r.stderr)
                self.assertNotIn('communications error', r.stdout)

    def test_partial_dns_requires_explicit_yes(self):
        for answer, accepted in [('y', True), ('Y', True), ('', False), ('n', False)]:
            with self.subTest(answer=answer):
                r = bash(DNS_MOCK + '''
                  sleep(){ exit 42; }
                  wait_dns s.example.test 192.0.2.10 <<< "$ANSWER"
                  echo ACCEPTED
                ''', env=dict(os.environ, SCENARIO='timeout', ANSWER=answer))
                self.assertEqual(r.returncode, 0 if accepted else 42, r.stderr)
                self.assertEqual('ACCEPTED' in r.stdout, accepted)
                self.assertNotIn('UNEXPECTED_ERR_TRAP', r.stdout + r.stderr)

    def test_conflicting_response_never_offers_override(self):
        r = bash(DNS_MOCK + '''
          sleep(){ exit 42; }
          wait_dns s.example.test 192.0.2.10 <<< y
          echo ACCEPTED
        ''', env=dict(os.environ, SCENARIO='mixed'))
        self.assertEqual(r.returncode, 42, r.stderr)
        self.assertNotIn('ACCEPTED', r.stdout)
        self.assertNotIn('Часть авторитетных NS', r.stdout)

    def test_no_ns_cannot_be_overridden(self):
        r = bash(DNS_MOCK + '''
          authoritative_ns(){ return 1; }
          dns_snapshot s.example.test 192.0.2.10
          if dns_ready || dns_partial_ready; then exit 1; fi
        ''', env=dict(os.environ, SCENARIO='ok'))
        self.assertEqual(r.returncode, 0, r.stderr)


class VersionTests(unittest.TestCase):
    def test_selection(self):
        for latest, choice, selected in [
            ('v3.8.5', '', 'v3.8.5'), ('', '', 'v3.8.5'),
            ('v3.8.0', '', 'v3.8.5'), ('v3.9.0', '1', 'v3.9.0'),
            ('v3.9.0', '', 'v3.8.5'), ('v3.9.0', '2', 'v3.8.5'),
        ]:
            with self.subTest(latest=latest, choice=choice):
                r = bash('''
                  warn(){ :; }
                  resolve_latest_xui_tag(){ printf '%s\n' "$LATEST"; }
                  choose_xui_version <<< "$CHOICE"
                  printf 'SELECTED=%s\n' "$XUI_SELECTED_TAG"
                ''', env=dict(os.environ, LATEST=latest, CHOICE=choice))
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn('SELECTED=' + selected, r.stdout)

    def test_fallback_order(self):
        cases = [
            ('v3.9.0', 'v3.9.0:upstream', ['v3.9.0:upstream']),
            ('v3.9.0', 'v3.8.5:upstream', ['v3.9.0:upstream', 'cleanup', 'v3.8.5:upstream']),
            ('v3.8.5', 'v3.8.0:upstream', ['v3.8.5:upstream', 'cleanup', 'v3.8.0:upstream']),
            ('v3.9.0', 'v3.8.0:mirror', ['v3.9.0:upstream', 'cleanup', 'v3.8.5:upstream', 'cleanup', 'v3.8.0:upstream', 'cleanup', 'v3.8.0:mirror']),
            ('v3.8.5', 'none', ['v3.8.5:upstream', 'cleanup', 'v3.8.0:upstream', 'cleanup', 'v3.8.0:mirror']),
        ]
        for selected, success, expected in cases:
            with self.subTest(selected=selected, success=success):
                r = bash('''
                  info(){ :; }; warn(){ :; }
                  install_xui_stack(){
                    printf '%s:%s\n' "$1" "${10}"
                    [[ "$1:${10}" == "$SUCCESS" ]]
                  }
                  cleanup_xui_fresh_attempt(){ echo cleanup; }
                  XUI_SELECTED_TAG="$SELECTED"
                  if install_xui_with_fallback 20001 dashboard-example /dashboard-example/ tester test example uuid client; then
                    printf 'ACTIVE=%s\n' "$XUI_ACTIVE_TAG"
                  else
                    echo FAILED
                  fi
                ''', env=dict(os.environ, SELECTED=selected, SUCCESS=success))
                self.assertEqual(r.returncode, 0, r.stderr)
                lines = r.stdout.splitlines()
                self.assertEqual(lines[:-1], expected)
                self.assertEqual(lines[-1], 'FAILED' if success == 'none' else 'ACTIVE=' + success.split(':')[0])


if __name__ == '__main__':
    unittest.main()
