# Third-party notices

Lintel includes the following third-party software. Its authors do not endorse Lintel.

## MediaRemote Adapter

Source: https://github.com/ungive/mediaremote-adapter (bundled as `MediaRemoteAdapter.framework`,
`MediaRemoteAdapterTestClient` and `mediaremote-adapter.pl`; built from the commit pinned in
`ThirdParty/mediaremote-adapter`). Used to read system-wide Now Playing information.

```
BSD 3-Clause License

Copyright (c) 2025, Jonas van den Berg and contributors

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Weather data: Open-Meteo

Source: https://open-meteo.com. Lintel requests the forecast from the Open-Meteo API at run time
(nothing is bundled). Weather data by Open-Meteo.com, licensed under the Creative Commons
Attribution 4.0 International licence (CC BY 4.0): https://creativecommons.org/licenses/by/4.0/.
Lintel shows this attribution in Settings next to the weather options.
