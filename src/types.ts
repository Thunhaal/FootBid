export type PlayerCategory = 'Current' | 'Icon' | 'Hero'
export type PositionCode =
  | 'GK' | 'RB' | 'LB' | 'CB' | 'RWB' | 'LWB'
  | 'CDM' | 'CM' | 'CAM' | 'RM' | 'LM'
  | 'RW' | 'LW' | 'CF' | 'ST'

export type TacticalRole =
  | 'GK' | 'CB' | 'LB' | 'RB' | 'DMF' | 'CMF' | 'AMF'
  | 'SS' | 'CF' | 'LWF' | 'RWF' | 'RMF' | 'LMF'

export type Player = {
  id: string
  name: string
  category: PlayerCategory
  base_price: number
  position: PositionCode[]
  best_known_for: string
  image: string
  image_source: string
  image_page_title: string
  image_attribution_url: string
  image_license_note: string
  image_status: string
  image_file_page_url: string
  image_lookup_url: string
  // Optional compatibility fields for rooms created by earlier FootBid prototypes.
  tier?: string
  rating?: number
  startBid?: number
}
export type OpeningPriceMultipliers = Record<PlayerCategory, number>
export type Settings = {
  budget: number
  squadSize: number
  auctionPoolSize: number
  openingPriceMultipliers: OpeningPriceMultipliers
  categoryCounts?: Record<PlayerCategory, number>
}
export type Purchase = { playerId: string; price: number }
export type PlayerPlacement = {
  playerId: string
  role: TacticalRole
  x: number
  y: number
}
export type Team = {
  id: string
  teamName: string
  budgetRemaining: number
  purchases: Purchase[]
  formation: string
  lineup: PlayerPlacement[]
  submitted: boolean
  isSeated: boolean
  isMine: boolean
}
export type RoomState = {
  id: string
  code: string
  status: 'lobby' | 'ready' | 'live' | 'finished'
  settings: Settings
  teams: Team[]
  poolPlayers: Player[]
  queueCount: number
  currentPlayer: Player | null
  currentBid: number
  highestBidderTeamId: string | null
  activeTeamIds: string[]
  lastMessage: string
  myTeamId: string
  isHost: boolean
}
export type MixMetric = {
  score: number
  label: string
  explanation: string
}
