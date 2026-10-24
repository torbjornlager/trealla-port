import unittest
from analyze_wire import decode_frames
def frame(op,payload,fin=True,masked=True):
 key=b'\x01\x82\x03\xff';body=bytes(b^key[i%4]for i,b in enumerate(payload))if masked else payload
 n=len(payload);length=bytes([n])if n<126 else b'\x7e'+n.to_bytes(2,'big')
 return bytes([(128 if fin else 0)|op,length[0]|(128 if masked else 0)])+length[1:]+(key if masked else b'')+body
class Tests(unittest.TestCase):
 def test_masked_ascii_and_long_unicode(self):
  rows,errors,tail=decode_frames(frame(1,b'{"command":"test"}')+frame(1,('å🙂'*100).encode()));self.assertFalse(errors);self.assertIsNone(tail);self.assertEqual(rows[0]['command_or_type'],'test');self.assertEqual(rows[1]['utf8'],'valid')
 def test_fragmented_utf8_with_ping(self):
  b='🙂'.encode();rows,e,t=decode_frames(frame(1,b[:2],False)+frame(9,b'ping')+frame(0,b[2:]));self.assertFalse(e);self.assertIsNone(t);self.assertEqual(rows[-1]['utf8'],'valid')
 def test_invalid_utf8(self):
  _,e,t=decode_frames(frame(1,b'{"x":"\xff"}'));self.assertEqual(e[0]['kind'],'invalid_text_utf8');self.assertIsNone(t)
 def test_wrong_mask_and_truncation(self):
  _,e,_=decode_frames(frame(1,b'ok',masked=False));self.assertEqual(e[0]['kind'],'invalid_frame_header');_,e,t=decode_frames(frame(1,b'ok')[:-1]);self.assertFalse(e);self.assertEqual(t['kind'],'incomplete_payload')
if __name__=='__main__':unittest.main()
