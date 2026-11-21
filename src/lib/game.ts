import { players } from '../data/players'
import type { Player } from '../types'

export function getPlayer(id:string,pool:Player[]=players):Player|undefined{
  return pool.find(player=>player.id===id)
}
export function getCategoryCounts(pool:Player[]){
  return {
    Current:pool.filter(p=>p.category==='Current').length,
    Icon:pool.filter(p=>p.category==='Icon').length,
    Hero:pool.filter(p=>p.category==='Hero').length
  }
}
export const categoryDescriptions={
  Current:'Active-era players',
  Icon:'Retired all-time greats',
  Hero:'Cult heroes and fan favourites'
}
