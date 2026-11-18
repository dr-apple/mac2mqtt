#pragma once
/// Schreibt den „Now Playing“-Zustand als JSON-Zeilen auf stdout (endlos).
/// Muss in einem Apple-Plattformprozess laufen (z. B. /usr/bin/perl), weil macOS 15.4+
/// MediaRemote für fremde Programme sperrt.
void mac2mqtt_np_stream(void);
