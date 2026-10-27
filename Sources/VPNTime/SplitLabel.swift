import VPNTimeCore

// "7h 40m  (VPN 6h 10m · bez VPN 1h 30m)"
func splitLabel(_ split: WorkSplit) -> String {
    L("split", hoursMinutes(split.total), hoursMinutes(split.vpn), hoursMinutes(split.noVPN))
}
