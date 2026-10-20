"""Training uses one GPU and bfloat16 only where the hardware has it."""

from dragonfarm.hardware import native_bf16
from dragonfarm.train import pin_one_gpu


class FakeCuda:
    def __init__(self, capability, emulated_ok=True, new_api=True):
        self.capability, self.emulated_ok, self.new_api = capability, emulated_ok, new_api

    def is_bf16_supported(self, including_emulation=None):
        if including_emulation is not None and not self.new_api:
            raise TypeError("unexpected keyword argument 'including_emulation'")
        native = self.capability[0] >= 8
        return native if including_emulation is False else (native or self.emulated_ok)

    def get_device_capability(self, i):
        return self.capability


class FakeTorch:
    def __init__(self, **kw):
        self.cuda = FakeCuda(**kw)


def test_a_t4_does_not_count_as_bfloat16():
    assert native_bf16(FakeTorch(capability=(7, 5))) is False                 # T4: emulated only
    assert native_bf16(FakeTorch(capability=(7, 5), new_api=False)) is False  # older torch
    assert native_bf16(FakeTorch(capability=(8, 9))) is True                  # RTX 4060
    assert native_bf16(FakeTorch(capability=(8, 0), new_api=False)) is True   # A100, older torch


def test_one_gpu_unless_devices_were_chosen():
    env = {}
    pin_one_gpu(env)
    assert env["CUDA_VISIBLE_DEVICES"] == "0"
    env = {"CUDA_VISIBLE_DEVICES": "1,2"}
    pin_one_gpu(env)
    assert env["CUDA_VISIBLE_DEVICES"] == "1,2"
