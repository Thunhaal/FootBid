import type { Player, PlayerPlacement, Team, PlayerCategory } from '../types'
import { roleSuitability, roleZones } from './tactics'

export type MetricKey='startingXI'|'bench'|'mix'|'balance'|'tactics'
export type ResultMetric={key:MetricKey;title:string;weight:number;score:number;detail:string}
export type PositionAnalysis={player:Player;role:PlayerPlacement['role'];suitability:number;effectiveStrength:number}
export type TeamResult={
  team:Team;rank:number;score:number;metrics:ResultMetric[];
  startingPlayers:Player[];benchPlayers:Player[];positionAnalysis:PositionAnalysis[];
  biggestStrength:ResultMetric;primaryReason:string
}

const MIN_PRICE=65
const MAX_PRICE=125
const normalise=(value:number)=>Math.max(0,Math.min(100,(value-MIN_PRICE)/(MAX_PRICE-MIN_PRICE)*100))
function getPlayers(team:Team,pool:Player[]):Player[]{
  const map=new Map(pool.map(player=>[player.id,player]))
  return team.purchases.map(purchase=>map.get(purchase.playerId)).filter((p):p is Player=>Boolean(p))
}
function average(values:number[]):number{return values.length?values.reduce((a,b)=>a+b,0)/values.length:0}
function mixScore(players:Player[]):number{
  if(!players.length)return 0
  const counts:Record<PlayerCategory,number>={Current:0,Icon:0,Hero:0}
  players.forEach(p=>counts[p.category]++)
  const total=players.length
  const entropy=Object.values(counts).filter(n=>n>0).reduce((sum,n)=>{
    const share=n/total
    return sum-share*Math.log(share)
  },0)
  return entropy/Math.log(3)*100
}
function squadBalanceScore(players:Player[],squadSize:number):{score:number;detail:string}{
  if(!players.length)return {score:0,detail:'No players purchased.'}
  const groups={GK:0,DEF:0,MID:0,ATT:0}
  players.forEach(player=>{
    const pos=player.position
    if(pos.includes('GK'))groups.GK++
    if(pos.some(p=>['CB','LB','RB','LWB','RWB'].includes(p)))groups.DEF++
    if(pos.some(p=>['CDM','CM','CAM','RM','LM'].includes(p)))groups.MID++
    if(pos.some(p=>['CF','ST','RW','LW'].includes(p)))groups.ATT++
  })
  const targets={GK:1,DEF:Math.max(2,Math.round(squadSize*.22)),MID:Math.max(3,Math.round(squadSize*.30)),ATT:Math.max(2,Math.round(squadSize*.22))}
  const score=average([
    Math.min(1,groups.GK/targets.GK),Math.min(1,groups.DEF/targets.DEF),
    Math.min(1,groups.MID/targets.MID),Math.min(1,groups.ATT/targets.ATT)
  ])*100
  return {score,detail:`Natural squad coverage — GK ${groups.GK} · DEF ${groups.DEF} · MID ${groups.MID} · ATT ${groups.ATT}`}
}
function coordinateFit(placement:PlayerPlacement):number{
  const target:Record<PlayerPlacement['role'],{x:number;y:number}>={
    GK:{x:50,y:92},CB:{x:50,y:75},LB:{x:22,y:76},RB:{x:78,y:76},
    DMF:{x:50,y:62},CMF:{x:50,y:51},AMF:{x:50,y:40},
    RMF:{x:82,y:53},LMF:{x:18,y:53},SS:{x:50,y:29},CF:{x:50,y:15},
    LWF:{x:23,y:25},RWF:{x:77,y:25}
  }
  const expected=target[placement.role]
  const dx=Math.abs(placement.x-expected.x)
  const dy=Math.abs(placement.y-expected.y)
  return Math.max(0,100-dx*1.8)*.4+Math.max(0,100-dy*1.8)*.6
}
function buildMetrics(team:Team,pool:Player[],squadSize:number):{
  metrics:ResultMetric[];startingPlayers:Player[];benchPlayers:Player[];positionAnalysis:PositionAnalysis[]
}{
  const owned=getPlayers(team,pool)
  const map=new Map(owned.map(p=>[p.id,p]))
  const placements=(team.lineup??[]).filter(p=>map.has(p.playerId)).slice(0,11)
  const positionAnalysis:PositionAnalysis[]=placements.map(placement=>{
    const player=map.get(placement.playerId)!
    const suitability=roleSuitability(player,placement.role)
    return {player,role:placement.role,suitability,effectiveStrength:normalise(player.base_price)*suitability/100}
  })
  const startingPlayers=positionAnalysis.map(item=>item.player)
  const startingIds=new Set(startingPlayers.map(p=>p.id))
  const benchPlayers=owned.filter(p=>!startingIds.has(p.id))
  const startingXI=average(positionAnalysis.map(item=>item.effectiveStrength))*Math.min(1,startingPlayers.length/11)

  const benchAvailability=Math.max(0,squadSize-11)
  const benchVersatility=average(benchPlayers.map(p=>Math.min(100,50+p.position.length*15)))/100
  const bench=benchAvailability===0?100:
    average(benchPlayers.map(p=>normalise(p.base_price)))*Math.min(1,benchPlayers.length/benchAvailability)*(.85+.15*benchVersatility)

  const mix=mixScore(owned)
  const balance=squadBalanceScore(owned,squadSize)
  const roleFit=average(positionAnalysis.map(item=>item.suitability))
  const positionalFit=average(placements.map(coordinateFit))
  const zones={GK:0,DEF:0,MID:0,ATT:0}
  placements.forEach(p=>{zones[roleZones[p.role]]++})
  const zoneCoverage=Object.values(zones).filter(v=>v>0).length/4*100
  const target={GK:1,DEF:4,MID:3,ATT:3}
  const meanDeviation=average((Object.keys(target) as Array<keyof typeof target>).map(zone=>Math.abs(zones[zone]-target[zone])))
  const shapeBalance=Math.max(0,100-meanDeviation*25)
  const tactics=roleFit*.55+positionalFit*.25+zoneCoverage*.10+shapeBalance*.10

  const naturalCount=positionAnalysis.filter(item=>item.suitability>=99).length
  const mismatchCount=positionAnalysis.length-naturalCount
  const worstMisfits=positionAnalysis.filter(item=>item.suitability<60)
  const metrics:ResultMetric[]=[
    {key:'startingXI',title:'Starting XI strength',weight:35,score:startingXI,detail:`${startingPlayers.length}/11 placed · ${naturalCount} natural role fits · ${mismatchCount} out-of-position`},
    {key:'bench',title:'Bench strength',weight:20,score:bench,detail:benchAvailability===0?'No bench places in an 11-player squad.':`${benchPlayers.length}/${benchAvailability} bench places filled · price strength and position versatility`},
    {key:'mix',title:'Current + Icons + Heroes mix',weight:15,score:mix,detail:`Current ${owned.filter(p=>p.category==='Current').length} · Icons ${owned.filter(p=>p.category==='Icon').length} · Heroes ${owned.filter(p=>p.category==='Hero').length}`},
    {key:'balance',title:'Squad balance',weight:15,score:balance.score,detail:balance.detail},
    {key:'tactics',title:'Tactical balance',weight:15,score:tactics,detail:`Natural role fit ${roleFit.toFixed(1)}/100 · positional layout ${positionalFit.toFixed(1)}/100 · ${Object.values(zones).filter(v=>v>0).length}/4 pitch lines covered`}
  ]
  if(worstMisfits.length){
    metrics[0].detail+=` · weakest fit: ${worstMisfits.slice().sort((a,b)=>a.suitability-b.suitability).slice(0,2).map(item=>`${item.player.name} at ${item.role} (${item.suitability}%)`).join(', ')}`
  }
  return {metrics,startingPlayers,benchPlayers,positionAnalysis}
}

export function calculateTeamResults(teams:Team[],pool:Player[],squadSize:number):TeamResult[]{
  const rows=teams.filter(team=>team.isSeated).map(team=>{
    const {metrics,startingPlayers,benchPlayers,positionAnalysis}=buildMetrics(team,pool,squadSize)
    const score=Math.round(metrics.reduce((sum,m)=>sum+m.score*m.weight/100,0)*10)/10
    return {team,rank:0,score,metrics,startingPlayers,benchPlayers,positionAnalysis,
      biggestStrength:metrics.reduce((a,b)=>b.score>a.score?b:a),primaryReason:''}
  }).sort((a,b)=>b.score-a.score ||
    b.metrics[0].score-a.metrics[0].score || b.metrics[4].score-a.metrics[4].score ||
    a.team.teamName.localeCompare(b.team.teamName))

  let prev:TeamResult|null=null
  rows.forEach((row,index)=>{
    const tied=prev&&row.score===prev.score&&row.metrics.every((m,i)=>m.score===prev!.metrics[i].score)
    row.rank=tied?prev!.rank:index+1
    prev=row
  })
  rows.forEach((row,index)=>{
    if(index===0){
      const runner=rows[1]
      if(!runner)row.primaryReason=`Built the strongest overall squad with a ${row.score.toFixed(1)}/100 score.`
      else if(runner.rank===row.rank)row.primaryReason=`Tied for first with ${runner.team.teamName} at ${row.score.toFixed(1)}/100.`
      else{
        const diffs=row.metrics.map((m,i)=>({metric:m,difference:(m.score-runner.metrics[i].score)*m.weight/100})).sort((a,b)=>b.difference-a.difference)
        const best=diffs[0]
        row.primaryReason=`Biggest weighted edge: ${best.metric.title.toLowerCase()} — ${best.metric.score.toFixed(1)}/100 vs ${runner.metrics.find(m=>m.key===best.metric.key)!.score.toFixed(1)}/100 for ${runner.team.teamName} (+${best.difference.toFixed(1)} final-score points).`
      }
    }else{
      const above=rows[index-1]
      if(row.rank===above.rank)row.primaryReason=`Tied with ${above.team.teamName} for place ${row.rank} at ${row.score.toFixed(1)}/100.`
      else{
        const diffs=row.metrics.map((m,i)=>({metric:m,difference:(above.metrics[i].score-m.score)*m.weight/100})).sort((a,b)=>b.difference-a.difference)
        const gap=above.score-row.score
        const place=row.rank===2?'second':row.rank===3?'third':`${row.rank}th`
        row.primaryReason=`Placed ${place} · ${gap.toFixed(1)} points behind ${above.team.teamName}. Biggest weighted gap: ${diffs[0].metric.title.toLowerCase()} — ${above.metrics.find(m=>m.key===diffs[0].metric.key)!.score.toFixed(1)} vs ${diffs[0].metric.score.toFixed(1)} (${diffs[0].difference.toFixed(1)} final-score points).`
      }
    }
  })
  return rows
}
