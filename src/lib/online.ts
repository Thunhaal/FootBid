import type { Player, PlayerPlacement, PositionCode, RoomState, Settings } from '../types'
import { supabase } from './supabase'
import { normaliseLegacyLineup } from './tactics'

function requireClient(){
  if(!supabase)throw new Error('Supabase is not configured. Copy .env.example to .env and add your project URL and anon/publishable key.')
  return supabase
}
let anonymousSessionPromise:Promise<unknown>|null=null
export async function ensureAnonymousSession(){
  if(anonymousSessionPromise)return anonymousSessionPromise
  anonymousSessionPromise=(async()=>{
    const client=requireClient()
    const {data:{session},error}=await client.auth.getSession()
    if(error)throw error
    if(session)return session
    const {data,error:signInError}=await client.auth.signInAnonymously()
    if(signInError)throw signInError
    if(!data.session)throw new Error('Could not create a guest session. Enable Anonymous Sign-Ins in Supabase Authentication settings.')
    return data.session
  })()
  try{return await anonymousSessionPromise}
  catch(e){anonymousSessionPromise=null;throw e}
}
export async function createOnlineRoom(args:{teamNames:string[];settings:Settings;pool:Player[];queue:string[]}){
  const client=requireClient()
  const {data,error}=await client.rpc('fb_create_room',{
    p_team_names:args.teamNames,
    p_settings:args.settings,
    p_pool_players:args.pool,
    p_queue:args.queue
  })
  if(error)throw error
  return data as {room_id:string;room_code:string;my_team_id:string}
}
export async function getRoomLobby(code:string){
  const client=requireClient()
  const {data,error}=await client.rpc('fb_get_room_lobby',{p_room_code:code.toUpperCase()})
  if(error)throw error
  return data as {room_id:string;room_code:string;status:string;settings:Settings;teams:{id:string;team_name:string;is_seated:boolean}[];my_team_id:string|null}
}
export async function joinOnlineRoom(code:string,teamId:string){
  const client=requireClient()
  const {data,error}=await client.rpc('fb_join_room',{p_room_code:code.toUpperCase(),p_team_id:teamId})
  if(error)throw error
  return data as {room_id:string;room_code:string;my_team_id:string}
}
function normalisePlayer(raw:any):Player{
  const legacyPositionMap:Record<string,PositionCode[]>={GK:['GK'],DEF:['CB','LB','RB'],MID:['CM','CAM','CDM'],FWD:['ST','CF']}
  const rawPosition=raw.position
  const position:PositionCode[]=Array.isArray(rawPosition)
    ? rawPosition
    : (legacyPositionMap[String(rawPosition)]??['CM'])
  const category=raw.category??(
    raw.tier==='ICON'?'Icon':
    raw.tier==='LEGENDARY'||raw.tier==='WORLD CLASS'?'Hero':'Current'
  )
  return {
    ...raw,
    category:category==='Icon'||category==='Hero'?category:'Current',
    base_price:Number(raw.base_price??raw.startBid??raw.rating??65),
    position,
    best_known_for:raw.best_known_for??raw.prime??'Legacy FootBid player card',
    image:raw.image??'',
    image_source:raw.image_source??'',
    image_page_title:raw.image_page_title??raw.name,
    image_attribution_url:raw.image_attribution_url??'',
    image_license_note:raw.image_license_note??'',
    image_status:raw.image_status??'unavailable',
    image_file_page_url:raw.image_file_page_url??'',
    image_lookup_url:raw.image_lookup_url??''
  } as Player
}
export async function fetchRoom(code:string):Promise<RoomState>{
  const client=requireClient()
  const {data,error}=await client.rpc('fb_room_snapshot',{p_room_code:code.toUpperCase()})
  if(error)throw error
  const raw=data as any
  const poolPlayers:Player[]=(raw.pool_players??[]).map(normalisePlayer)
  return {
    id:raw.room_id,code:raw.room_code,status:raw.status,settings:{...raw.settings,openingPriceMultipliers:{Current:1,Icon:1,Hero:1,...(raw.settings?.openingPriceMultipliers??{})}},
    teams:(raw.teams??[]).map((t:any)=>{
      const purchases=Array.isArray(t.purchases)?t.purchases:[]
      return {
        id:t.id,teamName:t.team_name,budgetRemaining:Number(t.budget_remaining),
        purchases,formation:t.formation??'CUSTOM',
        lineup:normaliseLegacyLineup(t.lineup??t.tactical_lineup,poolPlayers,purchases),
        submitted:Boolean(t.submitted),isSeated:Boolean(t.is_seated),isMine:Boolean(t.is_mine)
      }
    }),
    poolPlayers,
    queueCount:Number(raw.queue_count??0),
    currentPlayer:raw.current_player?normalisePlayer(raw.current_player):null,
    currentBid:Number(raw.current_bid??0),
    highestBidderTeamId:raw.highest_bidder_team_id??null,
    activeTeamIds:raw.active_team_ids??[],
    lastMessage:raw.last_message??'',
    myTeamId:raw.my_team_id,
    isHost:Boolean(raw.is_host)
  }
}
export async function startNextOnlinePlayer(code:string){
  const {error}=await requireClient().rpc('fb_start_next_player',{p_room_code:code.toUpperCase()})
  if(error)throw error
}
export async function placeOnlineBid(code:string,amount:number){
  const {error}=await requireClient().rpc('fb_place_bid',{p_room_code:code.toUpperCase(),p_amount:amount})
  if(error)throw error
}
export async function quitOnlineLot(code:string){
  const {error}=await requireClient().rpc('fb_quit_lot',{p_room_code:code.toUpperCase()})
  if(error)throw error
}
export async function updateMyTeam(code:string,formation:string,lineup:PlayerPlacement[]){
  const {error}=await requireClient().rpc('fb_update_my_team',{
    p_room_code:code.toUpperCase(),p_formation:formation,p_lineup:lineup
  })
  if(error)throw error
}
export async function submitMyTeam(code:string){
  const {error}=await requireClient().rpc('fb_submit_my_team',{p_room_code:code.toUpperCase()})
  if(error)throw error
}
export async function subscribeRoom(code:string,roomId:string,onChange:()=>void){
  const client=requireClient()
  const channel=client.channel(`footbid-room-${roomId}`)
    .on('postgres_changes',{event:'*',schema:'public',table:'fb_rooms',filter:`id=eq.${roomId}`},onChange)
    .on('postgres_changes',{event:'*',schema:'public',table:'fb_teams',filter:`room_id=eq.${roomId}`},onChange)
    .subscribe()
  return ()=>{void client.removeChannel(channel)}
}

export async function kickOnlineTeam(code:string,teamId:string){
  const {error}=await requireClient().rpc('fb_host_kick_team',{
    p_room_code:code.toUpperCase(),p_team_id:teamId
  })
  if(error)throw error
}
export async function leaveOnlineRoom(code:string){
  const {error}=await requireClient().rpc('fb_leave_room',{p_room_code:code.toUpperCase()})
  if(error)throw error
}
