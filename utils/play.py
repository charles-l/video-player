import numpy as np
import matplotlib.pyplot as plt
import sounddevice as sd
r = np.fromfile('audio_data.bin', dtype=np.short)

sd.play(r, 44100 * 2)

plt.plot(r)
plt.show()
