package system

import (
	"net"
	"strconv"
	"strings"
)

// NetworkDiscovery 供客户端局域网快传探测（公开接口，无需登录）。
type NetworkDiscovery struct {
	ListenPort    int      `json:"listen_port"`
	PublicBaseURL string   `json:"public_base_url"`
	LANIPv4       []string `json:"lan_ipv4"`
}

func (s *Service) NetworkDiscovery() NetworkDiscovery {
	port := ParseListenPort(s.Listen)
	return NetworkDiscovery{
		ListenPort:    port,
		PublicBaseURL: s.PublicBaseURL,
		LANIPv4:       ListLANIPv4(),
	}
}

// ParseListenPort 从 "host:port" 或 ":port" 解析端口；失败时返回 0。
func ParseListenPort(listen string) int {
	listen = strings.TrimSpace(listen)
	if listen == "" {
		return 0
	}
	// net.SplitHostPort 需要 host；":10002" 可写成 "0.0.0.0:10002" 的变形
	if strings.HasPrefix(listen, ":") {
		listen = "0.0.0.0" + listen
	}
	_, portStr, err := net.SplitHostPort(listen)
	if err != nil {
		return 0
	}
	p, err := strconv.Atoi(portStr)
	if err != nil {
		return 0
	}
	return p
}

// ListLANIPv4 返回本机非回环、非链路本地的 IPv4（用于局域网访问）。
func ListLANIPv4() []string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	var out []string
	seen := map[string]struct{}{}
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			ip := addrIP(addr)
			if ip == nil || ip.To4() == nil {
				continue
			}
			if ip.IsLoopback() || ip.IsLinkLocalUnicast() || !ip.IsPrivate() {
				continue
			}
			s := ip.String()
			if _, ok := seen[s]; ok {
				continue
			}
			seen[s] = struct{}{}
			out = append(out, s)
		}
	}
	// 优先更常见的家庭网段
	sortLAN(out)
	return out
}

func addrIP(addr net.Addr) net.IP {
	switch v := addr.(type) {
	case *net.IPNet:
		return v.IP
	case *net.IPAddr:
		return v.IP
	default:
		return nil
	}
}

func sortLAN(ips []string) {
	score := func(ip string) int {
		if strings.HasPrefix(ip, "192.168.") {
			return 0
		}
		if strings.HasPrefix(ip, "10.") {
			return 1
		}
		if strings.HasPrefix(ip, "172.") {
			return 2
		}
		return 3
	}
	for i := 0; i < len(ips); i++ {
		for j := i + 1; j < len(ips); j++ {
			if score(ips[j]) < score(ips[i]) {
				ips[i], ips[j] = ips[j], ips[i]
			}
		}
	}
}
