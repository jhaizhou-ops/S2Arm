#!/usr/bin/env python3
"""一包通用（10-30 总指挥）：直连包出 iPhone 包不要目标设备（pack/jobs/ipa.py resolve_target required=False）。
   新用例单独成文件（列车线 10-30：公用大测试文件人人往里加，合入时互相冲突）。"""
import unittest
from unittest.mock import patch

from jobcase import JobCase
from core import Failure
import ipa
import target


class DirectTargetOptional(JobCase):

    def test_direct_pack_target_is_optional(self):
        """一包通用（10-30）：直连包不要目标设备；SDK 比目标旧不拦；目标装不了照旧拦。反证：兼容模式（required）没目标照旧 target_required"""
        self.c.r.pop("target", None)
        for devices in ([], [dict(gpuArch="applegpu_g17p", os=26), dict(gpuArch="applegpu_g18p", os=27)]):
            with self.subTest(devices=devices), patch.object(target, "connected", return_value=devices):
                self.assertIsNone(ipa.resolve_target(self.c, required=False))
                with self.assertRaises(Failure) as raised:
                    ipa.resolve_target(self.c)
                self.assertEqual(raised.exception.code, "target_required")
        with patch.object(target, "connected", side_effect=target.TargetError("probe broke", code="target_required")):
            self.assertIsNone(ipa.resolve_target(self.c, required=False))
        self.c.r["target"] = dict(model="fixture", gpuArch="applegpu_g18p", os=27)
        with patch.object(target, "os_choices", return_value=[26]):
            self.assertEqual(ipa.resolve_target(self.c, required=False)["os"], 27)
            with self.assertRaises(Failure) as raised:
                ipa.resolve_target(self.c)
            self.assertEqual(raised.exception.code, "xcode_sdk_too_old")
        self.c.r["target"] = dict(model="fixture", gpuArch="applegpu_g17p", os=17)
        with patch.object(target, "os_choices", return_value=[27]):
            with self.assertRaises(Failure) as raised:
                ipa.resolve_target(self.c, required=False)
            self.assertEqual(raised.exception.code, "target_unsupported")



if __name__ == "__main__":
    unittest.main()
