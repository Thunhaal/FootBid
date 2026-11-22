import { players } from '../data/players'
import type { Player, PlayerCategory } from '../types'

export const STARTER_POOL_SIZE = 90
export const CANDIDATE_POOL_SIZE = players.length
export const CATEGORY_ORDER:PlayerCategory[]=['Current','Icon','Hero']
export const CATEGORY_COLORS:Record<PlayerCategory,string>={
  Current:'category-current',Icon:'category-icon',Hero:'category-hero'
}

function shuffleInPlace<T>(items:T[]):T[]{
  const result=[...items]
  for(let i=result.length-1;i>0;i--){
    const j=Math.floor(Math.random()*(i+1))
    ;[result[i],result[j]]=[result[j],result[i]]
  }
  return result
}

/** Randomly samples each category in proportion to the uploaded dataset's 318/82/89 split. */
export function categoryQuotas(size:number):Record<PlayerCategory,number>{
  const target=Math.max(STARTER_POOL_SIZE,Math.min(players.length,Math.floor(size)))
  const counts=CATEGORY_ORDER.map(category=>players.filter(p=>p.category===category).length)
  const exact=counts.map(count=>target*count/players.length)
  const quotas=exact.map(Math.floor)
  let remaining=target-quotas.reduce((a,b)=>a+b,0)
  const order=exact.map((value,index)=>({index,remainder:value-quotas[index]})).sort((a,b)=>b.remainder-a.remainder)
  for(let i=0;i<remaining;i++)quotas[order[i].index]++
  return Object.fromEntries(CATEGORY_ORDER.map((category,index)=>[category,quotas[index]])) as Record<PlayerCategory,number>
}
export function categoryCounts(pool:Player[]):Record<PlayerCategory,number>{
  return Object.fromEntries(CATEGORY_ORDER.map(category=>[category,pool.filter(p=>p.category===category).length])) as Record<PlayerCategory,number>
}
export function shuffleItems<T>(items:T[]):T[]{return shuffleInPlace(items)}
export function drawAuctionPool(
  size=STARTER_POOL_SIZE,
  requestedCounts:Record<PlayerCategory,number>=categoryQuotas(size)
):Player[]{
  const target=Math.floor(size)
  if(!Number.isInteger(target)||target<STARTER_POOL_SIZE||target>players.length){
    throw new Error('Auction size must be between '+STARTER_POOL_SIZE+' and '+players.length+'.')
  }
  const total=CATEGORY_ORDER.reduce((sum,category)=>sum+requestedCounts[category],0)
  if(total!==target)throw new Error('Current, Icon and Hero counts must add up to exactly '+target+'.')
  const selected:Player[]=[]
  for(const category of CATEGORY_ORDER){
    const count=requestedCounts[category]
    const available=players.filter(player=>player.category===category)
    if(!Number.isInteger(count)||count<0||count>available.length){
      throw new Error(category+' count must be between 0 and '+available.length+'.')
    }
    selected.push(...shuffleInPlace(available).slice(0,count))
  }
  return shuffleInPlace(selected)
}
export function shuffleQueue(pool:Player[]):string[]{return shuffleInPlace(pool.map(player=>player.id))}
