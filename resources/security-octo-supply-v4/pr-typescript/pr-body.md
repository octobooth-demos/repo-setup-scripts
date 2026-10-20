Implements downloadable Terms & Conditions with multi-language support and basic bot filtering using ua-parser-js to reduce automated scraping and potential DDoS amplification on the new download endpoint.

Includes: 
- Footer link exposing Terms & Conditions download
- Language variant resolution logic
- Basic user-agent inspection (ua-parser-js) to short-circuit known crawler / AI bot patterns before expensive work
- Documentation & tests for new route

Related to demo setup
