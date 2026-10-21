"""A finished run records its peak GPU memory (torch's count) when there is a GPU."""

from dragonfarm.train import peak_gpu


def test_peak_gpu_is_a_number_or_nothing():
    p = peak_gpu()
    assert p == {} or (set(p) == {"peak_gpu_gb"} and p["peak_gpu_gb"] >= 0)
