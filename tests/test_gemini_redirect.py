"""Regressions for the real default-curl CAPTCHA misclassification."""
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from test_features_v4 import g
from test_autopin import m


class GeminiRedirectTests(unittest.TestCase):
    def request(self,headers,page='',profile=None,rc=0):
        def curl(args,timeout=90,executable='curl'):
            Path(args[args.index('-D')+1]).write_text(headers)
            # Keep all probes on the selected instance, including DNS.
            self.assertEqual(args[args.index('--proxy')+1],'socks5h://127.0.0.1:40002')
            self.assertEqual(args[args.index('--noproxy')+1],'')
            return rc,page,'network unavailable' if rc else ''
        with patch.object(g,'curl',side_effect=curl),patch.object(g,'model_request') as model:
            verdict,reason=g.check(40002,profile)
        model.assert_not_called()
        return verdict,reason
    def test_default_curl_google_sorry_redirect_is_captcha_not_inconclusive(self):
        verdict,reason=self.request('HTTP/2 302\r\nlocation: https://www.google.com/sorry/index?continue=https://gemini.google.com/app\r\n','<title>302 Moved</title>')
        self.assertEqual(verdict,'CAPTCHA');self.assertIn('Google CAPTCHA',reason)
    def test_browser_profile_retains_identical_captcha_classification(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp)/'curl_chrome140').touch()
            self.assertEqual(self.request('HTTP/2 302\nLocation: https://www.google.com/sorry/index\n',profile=tmp)[0],'CAPTCHA')
    def test_unknown_application_page_remains_inconclusive(self):
        self.assertEqual(self.request('HTTP/2 200\nContent-Type: text/html\n','<html>Unknown response</html>')[0],'INCONCLUSIVE')
    def test_unrelated_redirect_is_not_classified_as_google_captcha(self):
        for location in ('https://accounts.google.com/ServiceLogin','https://example.invalid/sorry/index','https://www.google.com/search?q=sorry'):
            with self.subTest(location=location):
                self.assertEqual(self.request('HTTP/2 302\nLocation: '+location+'\n')[0],'INCONCLUSIVE')
    def test_page_fetch_failure_is_still_inconclusive(self):
        self.assertEqual(self.request('',rc=7)[0],'INCONCLUSIVE')
    def test_valid_model_response_is_still_serving(self):
        page='"cfb2h":"build" "FdrFJe":"session"'
        with patch.object(g,'curl',return_value=(0,page,'')),patch.object(g,'model_request',return_value=(0,'wrb.fr SWML_DESCRIPTION','')):
            self.assertEqual(g.check(40000)[0],'SERVING')
    def test_explicit_captcha_rejects_adoption_and_triggers_confirmed_rotation(self):
        verdict,_=self.request('HTTP/2 302\nLocation: https://www.google.com/sorry/index\n')
        completed=subprocess.CompletedProcess([],3,stdout=verdict+': request redirected to Google CAPTCHA',stderr='')
        with tempfile.TemporaryDirectory() as tmp,patch.object(m,'POLICY',{}),patch.object(m,'DATA',Path(tmp)),patch.object(m,'STATE',Path(tmp)/'state.json'),patch.object(m,'CONFIG',Path(tmp)/'config.json'),patch.object(m,'BASE',Path(tmp)),patch.object(m,'PROXY','127.0.0.1:40002'),patch.object(m,'probe',return_value=('192.0.2.1','NL')),patch.object(m.subprocess,'run',return_value=completed):
            observed=m.evaluate_exit('NL',True,0)
            self.assertEqual(observed[-1],'Gemini CAPTCHA')
            with patch.object(m,'auto_pin_current') as pin:
                self.assertFalse(m.adopt_current('NL',True,0,False,observed=observed))
            pin.assert_not_called()
            with patch.object(m,'wait_ready'),patch.object(m,'connected_id',return_value='abcdefgh'),patch.object(m,'started_at',return_value='start'),patch.object(m,'search') as search,patch.object(m.time,'sleep',side_effect=[None,KeyboardInterrupt]):
                with self.assertRaises(KeyboardInterrupt):m.monitor('NL',300,75,12,gemini=True)
            search.assert_called_once_with('NL',75,12,True,0,False)


if __name__=='__main__':unittest.main()
