import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest

root=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('usb_updater',root/'scripts/esp32-usb-update.py')
updater=importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)


class UpdaterTest(unittest.TestCase):
    def test_status_identity_and_protocol(self):
        packet=b'MLUPD001'+bytes([1,0])+bytes.fromhex('b81f3fc46e40')+bytes(range(16))
        self.assertEqual(updater.parse_status(packet),'b8:1f:3f:c4:6e:40')
        for invalid in [packet[:-1],packet+b'0',b'BADMAGIC'+packet[8:],packet[:8]+b'\x02\x00'+packet[10:],packet[:9]+b'\x01'+packet[10:]]:
            with self.subTest(invalid=invalid),self.assertRaises(ValueError):updater.parse_status(invalid)

    def test_mac_validation(self):
        self.assertEqual(updater.normalize_mac('B81F3FC46E40'),'b8:1f:3f:c4:6e:40')
        for value in ['', 'b81f3fc46e4','zz1f3fc46e40','b81f3fc46e4000']:
            with self.subTest(value=value),self.assertRaises(ValueError):updater.normalize_mac(value)

    def test_image_and_hash_checked_before_device_switch(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'app.bin'
            data=bytearray(256);data[0]=0xe9;data[12]=9
            path.write_bytes(data)
            digest=hashlib.sha256(data).hexdigest()
            self.assertEqual(updater.validate_firmware(path,digest),digest)
            with self.assertRaises(ValueError):updater.validate_firmware(path,'0'*64)
            with self.assertRaises(ValueError):updater.validate_firmware(path)
            data[12]=0;path.write_bytes(data)
            with self.assertRaises(ValueError):updater.validate_firmware(path,hashlib.sha256(data).hexdigest())


if __name__=='__main__':unittest.main()
