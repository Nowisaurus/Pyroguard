import 'package:flutter/material.dart';
import '../../theme.dart';
import 'dashboard_models.dart';
class SystemStatusStrip extends StatelessWidget {
  const SystemStatusStrip({super.key,required this.data});
  final DashboardSnapshot? data;
  @override Widget build(BuildContext context) {
    final items=<({String name,String status,bool? online,IconData icon})>[
      (name:'Supabase',status:data?.supabaseReachable == true?'ONLINE':'NOT VERIFIED',online:data?.supabaseReachable,icon:Icons.cloud_done_outlined),
      (name:'MySQL Mirror',status:data?.mysqlLabel??'NOT VERIFIED',online:null,icon:Icons.storage_outlined),
      (name:'Main ESP32',status:data?.main.connectionText??'NO DATA',online:data?.main.connected,icon:Icons.memory_outlined),
      (name:'Secondary ESP32',status:data?.secondary.connectionText??'NO DATA',online:data?.secondary.connected,icon:Icons.developer_board_outlined),
      (name:'Camera 1 (two-way)',status:data?.camera1.online==true?'ONLINE':'NO FRESH HEARTBEAT',online:data?.camera1.online,icon:Icons.videocam_outlined),
    ];
    return LayoutBuilder(builder:(context,c){
      final columns=c.maxWidth>=950?3:c.maxWidth>=520?2:1;
      final width=(c.maxWidth-(columns-1)*9)/columns;
      return Wrap(spacing:9,runSpacing:9,children:items.map((x){
        final color=x.online==true?AppColors.green:x.online==false?AppColors.amber:AppTheme.textSecondary(context);
        return Container(width:width,padding:const EdgeInsets.symmetric(horizontal:12,vertical:11),decoration:GlassStyle.card(light:!AppTheme.isDark(context),border:color.withValues(alpha:.25)),child:Row(children:[Icon(x.icon,size:19,color:color),const SizedBox(width:9),Expanded(child:Text(x.name,style:TextStyle(color:AppTheme.textPrimary(context),fontWeight:FontWeight.w700,fontSize:12))),Flexible(child:Text(x.status,textAlign:TextAlign.right,style:TextStyle(color:color,fontWeight:FontWeight.w800,fontSize:10)))]));
      }).toList());
    });
  }
}
