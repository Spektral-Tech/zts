package manifest

import "fmt"

const presetHead = `# ZTS manifest. Profiles declare what a workload may reach; nothing else exists.
# Attach a container with:  docker run --network none --label zts.profile=<profile> ...
version: 1

substrate:
  namespace: zts
  pool: 100.64.0.0/10

transports:
  # Egress through this host's own default route. Private and link-local
  # destinations are never reachable this way unless a resource lists a CIDR.
  host:
    type: host

`

var presets = map[string]string{
	"coding-agent": `resources:
  github:
    names: [github.com, "*.github.com", "*.githubusercontent.com"]
  package-registries:
    names:
      - registry.npmjs.org
      - pypi.org
      - files.pythonhosted.org
      - proxy.golang.org
      - sum.golang.org
      - crates.io
      - "*.crates.io"
  model-apis:
    names: [api.anthropic.com, api.openai.com]

profiles:
  isolated:
    allow: []

  dev:
    allow:
      - { to: github,             via: host, protocol: tcp, ports: [443] }
      - { to: package-registries, via: host, protocol: tcp, ports: [443] }
      - { to: model-apis,         via: host, protocol: tcp, ports: [443] }
`,
	"web-dev": `resources:
  # Any name, any public address, web ports only. Host, LAN and link-local
  # stay unreachable (see transports.host).
  internet:
    names: ["*"]

profiles:
  isolated:
    allow: []

  dev:
    allow:
      - { to: internet, via: host, protocol: tcp, ports: [80, 443] }
`,
	"isolated": `resources: {}

profiles:
  isolated:
    allow: []
`,
}

// Preset returns the manifest text for a preset name.
func Preset(name string) (string, error) {
	body, ok := presets[name]
	if !ok {
		return "", fmt.Errorf("unknown preset '%s' (coding-agent, web-dev, isolated)", name)
	}
	return presetHead + body, nil
}

func PresetNames() []string { return []string{"coding-agent", "web-dev", "isolated"} }
