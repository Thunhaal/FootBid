import type { Player, PlayerPlacement, TacticalRole } from '../types'

export const tacticalRoles:TacticalRole[]=[
  'GK','CB','LB','RB','DMF','CMF','AMF','RMF','LMF','SS','CF','RWF','LWF'
]

export const roleLabel:Record<TacticalRole,string>={
  GK:'Goalkeeper', CB:'Centre Back', LB:'Left Back', RB:'Right Back',
  DMF:'Defensive Midfielder', CMF:'Central Midfielder', AMF:'Attacking Midfielder',
  RMF:'Right Midfielder', LMF:'Left Midfielder', SS:'Second Striker',
  CF:'Centre Forward', RWF:'Right Wing Forward', LWF:'Left Wing Forward'
}

export const roleZones:Record<TacticalRole,'GK'|'DEF'|'MID'|'ATT'>={
  GK:'GK', CB:'DEF', LB:'DEF', RB:'DEF',
  DMF:'MID', CMF:'MID', AMF:'MID', RMF:'MID', LMF:'MID',
  SS:'ATT', CF:'ATT', LWF:'ATT', RWF:'ATT'
}

export const rolePositions:Record<TacticalRole,string[]>={
  GK:['GK'], CB:['CB'], LB:['LB','LWB'], RB:['RB','RWB'],
  DMF:['CDM'], CMF:['CM'], AMF:['CAM'], RMF:['RM'], LMF:['LM'],
  SS:['ST','CF'], CF:['CF','ST'], LWF:['LW'], RWF:['RW']
}

export const roleInitialPosition:Record<TacticalRole,{x:number;y:number}>={
  GK:{x:50,y:92}, CB:{x:50,y:75}, LB:{x:22,y:76}, RB:{x:78,y:76},
  DMF:{x:50,y:62}, CMF:{x:50,y:51}, AMF:{x:50,y:40},
  RMF:{x:82,y:53}, LMF:{x:18,y:53},
  SS:{x:50,y:29}, CF:{x:50,y:15}, LWF:{x:23,y:25}, RWF:{x:77,y:25}
}

const positionZone:Record<string,'GK'|'DEF'|'MID'|'ATT'>={
  GK:'GK',CB:'DEF',LB:'DEF',RB:'DEF',LWB:'DEF',RWB:'DEF',
  CDM:'MID',CM:'MID',CAM:'MID',RM:'MID',LM:'MID',
  RW:'ATT',LW:'ATT',CF:'ATT',ST:'ATT'
}

export function eligibleRoles(player:Player):TacticalRole[]{
  const positions=Array.isArray(player.position)?player.position:[player.position as unknown as string]
  return tacticalRoles.filter(role=>rolePositions[role].some(pos=>positions.includes(pos)))
}

export function defaultRole(player:Player):TacticalRole{
  const preferred=(Array.isArray(player.position)?player.position:[player.position as unknown as string])[0]
  const map:Record<string,TacticalRole>={
    GK:'GK',CB:'CB',LB:'LB',LWB:'LB',RB:'RB',RWB:'RB',
    CDM:'DMF',CM:'CMF',CAM:'AMF',RM:'RMF',LM:'LMF',
    CF:'CF',ST:'SS',LW:'LWF',RW:'RWF'
  }
  return map[preferred]??eligibleRoles(player)[0]??'CMF'
}

/** Position on the pitch chooses the tactical role. x=0 is left, y=100 is own goal. */
export function roleFromCoordinates(x:number,y:number):TacticalRole{
  const px=Math.max(0,Math.min(100,x))
  const py=Math.max(0,Math.min(100,y))

  // Goal area: centre is GK; left/right channels are full-back positions.
  if(py>=85){
    if(px<34)return 'LB'
    if(px>66)return 'RB'
    return 'GK'
  }
  // Defensive line: centre backs in the middle, full-backs wide.
  if(py>=66){
    if(px<35)return 'LB'
    if(px>65)return 'RB'
    return 'CB'
  }
  // Midfield: deeper central, central, advanced central; wide lanes are LMF/RMF.
  if(py>=54){
    if(px<25)return 'LMF'
    if(px>75)return 'RMF'
    return 'DMF'
  }
  if(py>=44){
    if(px<25)return 'LMF'
    if(px>75)return 'RMF'
    return 'CMF'
  }
  if(py>=35){
    if(px<25)return 'LWF'
    if(px>75)return 'RWF'
    return 'AMF'
  }
  // Final third: wide forwards, second striker behind the centre-forward.
  if(px<29)return 'LWF'
  if(px>71)return 'RWF'
  if(py>=23)return 'SS'
  return 'CF'
}

/**
 * Suitability score for using a player in a tactical role.
 * Natural positions score 100; same-line alternatives score well; out-of-position
 * use is allowed but heavily penalised, especially GK outfield and outfield at GK.
 */
export function roleSuitability(player:Player,role:TacticalRole):number{
  const positions=Array.isArray(player.position)?player.position:[player.position as unknown as string]
  const direct=rolePositions[role]
  if(direct.some(position=>positions.includes(position)))return 100

  const naturalZones=[...new Set(positions.map(position=>positionZone[position]).filter(Boolean))]
  const targetZone=roleZones[role]
  if(naturalZones.includes(targetZone))return 76
  if(naturalZones.includes('GK')||targetZone==='GK')return 5

  const transitions:Record<string,Record<string,number>>={
    DEF:{MID:44,ATT:24},
    MID:{DEF:48,ATT:55},
    ATT:{MID:47,DEF:22}
  }
  return Math.max(8,...naturalZones.map(zone=>transitions[zone]?.[targetZone]??8))
}

export function isRoleCompatible(player:Player,role:TacticalRole):boolean{
  return roleSuitability(player,role)>=76
}

export function autoPlacePlayers(purchases:{playerId:string}[],pool:Player[],existing:PlayerPlacement[]=[]):PlayerPlacement[]{
  const owned=new Set(purchases.map(p=>p.playerId))
  const result=existing.filter(p=>owned.has(p.playerId)).slice(0,11).map(p=>({
    ...p,role:roleFromCoordinates(p.x,p.y)
  }))
  const placed=new Set(result.map(p=>p.playerId))
  for(const purchase of purchases){
    if(result.length>=11)break
    if(placed.has(purchase.playerId))continue
    const player=pool.find(p=>p.id===purchase.playerId)
    if(!player)continue
    const role=defaultRole(player)
    const point=roleInitialPosition[role]
    const sameRole=result.filter(p=>p.role===role)
    const x=Math.max(8,Math.min(92,point.x+(sameRole.length%2===0?sameRole.length*5:-sameRole.length*5)))
    const y=Math.max(8,Math.min(96,point.y+Math.floor(sameRole.length/2)*4))
    result.push({playerId:player.id,role:roleFromCoordinates(x,y),x,y})
    placed.add(player.id)
  }
  return result
}

export function normaliseLegacyLineup(raw:unknown,pool:Player[],purchases:{playerId:string}[]):PlayerPlacement[]{
  if(Array.isArray(raw)){
    return raw.map((item:any)=>{
      const x=Math.max(3,Math.min(97,Number(item.x??50)))
      const y=Math.max(3,Math.min(97,Number(item.y??50)))
      return {playerId:String(item.playerId??''),role:roleFromCoordinates(x,y),x,y}
    }).filter(p=>pool.some(player=>player.id===p.playerId)).slice(0,11)
  }
  if(raw && typeof raw==='object'){
    const values=Object.values(raw as Record<string,unknown>).map(String)
    const unique=[...new Set(values)]
    return autoPlacePlayers(unique.map(playerId=>({playerId})),pool,[])
  }
  return autoPlacePlayers(purchases,pool,[])
}

export function formationLabel(lineup:PlayerPlacement[]):string{
  const counts={GK:0,DEF:0,MID:0,ATT:0}
  for(const placement of lineup)counts[roleZones[placement.role]]++
  return `${counts.GK}-${counts.DEF}-${counts.MID}-${counts.ATT} · FREE POSITIONING`
}
