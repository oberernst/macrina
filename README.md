# Macrina

Saint Macrina, patron of Robotics, ora pro nobis
---
UNDER CONSTRUCTION! It's still a rough draft that I'm ripping to shreds constantly. LMK if you'd like this to change
* CoAP binary request encoding and decoding (RFC 7253.3)
* Endpoint 
  * can receive and decode messages
  * de-dups messages based on incoming IP/Port and `message_id`
  * echoes requests
  * can be started with arbitrary `handler` function for extending functionality

## Overview
Macrina is an attempt to hew as close as possible to the language of the RFC. As such, the `Endpoint` is the root of the concept. Starting an `Endpoint` with a given IP and Port combination is analogous to binding a webserver implementation to `"127.0.0.1:4000"`. The `Endpoint` itself is a `GenServer` that opens a UDP socket with `:gen_udp`. Incoming UDP packets are dispatched to `Connection` processes, one per sender IP/Port. The `Connection` handles decoding the binary CoAP message into a `Macrina.Message` and does two things with any given message: calls a provided `Handler` `call/2` function whose purpose is replying to the CoAP request, and routes that message to any `Macrina.Client` that may have been expecting it as the response to some call it made. This illustrates an important point: the `Connection` module is used by `Macrina.Client` for sending outbound requests as well as by the app internally as a server implementation piece.

## Notes
All thanks to @tpitale for his work on the actual CoAP (de|en)coding that I shamelessly copied
