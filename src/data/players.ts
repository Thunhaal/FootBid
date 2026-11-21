import database from './football_auction_players.json'
import type { Player } from '../types'

export const players = database.players as Player[]
export const datasetMetadata = {
  name: database.dataset_name,
  version: database.dataset_version,
  totalPlayers: database.total_players,
  categories: database.categories
}
